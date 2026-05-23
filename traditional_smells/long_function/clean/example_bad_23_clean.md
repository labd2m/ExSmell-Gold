```elixir
defmodule Reporting.CustomerLifetimeValue do
  @moduledoc """
  Computes Customer Lifetime Value (CLV) for a given customer based on
  historical purchase data, projected retention, and a discounted cash-flow model.
  """

  alias Reporting.{ClvRecord, Repo}
  alias Sales.Order
  alias Integrations.CrmSync
  require Logger

  @discount_rate 0.10
  @projection_years 3
  @churn_base_rate 0.25
  @tier_thresholds %{platinum: 10_000, gold: 5_000, silver: 1_000}

  def compute(customer_id, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    Logger.info("Computing CLV for customer=#{customer_id}")

    # --- Return cached record if recent and refresh not forced ---
    existing =
      ClvRecord
      |> ClvRecord.for_customer(customer_id)
      |> ClvRecord.most_recent()
      |> Repo.one()

    if existing && not force_refresh &&
         DateTime.diff(DateTime.utc_now(), existing.computed_at, :second) < 86_400 do
      Logger.debug("Returning cached CLV for customer #{customer_id}")
      {:ok, existing}
    else
      # --- Fetch completed orders ---
      orders =
        Order
        |> Order.for_customer(customer_id)
        |> Order.completed()
        |> Order.order_by_date(:asc)
        |> Repo.all()

      order_count = length(orders)

      if order_count == 0 do
        {:ok, %{customer_id: customer_id, clv: 0.0, tier: :none, order_count: 0}}
      else
        # --- Compute average order value ---
        total_revenue = Enum.reduce(orders, 0.0, fn o, acc -> acc + o.total end)
        avg_order_value = total_revenue / order_count

        # --- Compute purchase frequency (orders per year) ---
        first_order_date = hd(orders).inserted_at
        last_order_date  = List.last(orders).inserted_at

        days_active =
          max(DateTime.diff(last_order_date, first_order_date, :second) |> div(86_400), 1)

        orders_per_year = order_count / (days_active / 365.0)

        # --- Estimate churn probability based on recency ---
        days_since_last_order =
          DateTime.diff(DateTime.utc_now(), last_order_date, :second) |> div(86_400)

        recency_churn_factor =
          cond do
            days_since_last_order < 30  -> 0.0
            days_since_last_order < 90  -> 0.1
            days_since_last_order < 180 -> 0.25
            days_since_last_order < 365 -> 0.50
            true                        -> 0.80
          end

        churn_probability = min(@churn_base_rate + recency_churn_factor, 1.0)
        retention_rate = 1.0 - churn_probability

        # --- Discounted cash-flow projection ---
        annual_value = avg_order_value * orders_per_year

        clv =
          Enum.reduce(1..@projection_years, 0.0, fn year, acc ->
            retained_value = annual_value * :math.pow(retention_rate, year)
            discounted     = retained_value / :math.pow(1 + @discount_rate, year)
            acc + discounted
          end)

        clv_rounded = Float.round(clv, 2)

        # --- Assign tier ---
        tier =
          cond do
            clv_rounded >= @tier_thresholds.platinum -> :platinum
            clv_rounded >= @tier_thresholds.gold     -> :gold
            clv_rounded >= @tier_thresholds.silver   -> :silver
            true                                     -> :bronze
          end

        # --- Persist CLV record ---
        {:ok, record} =
          Repo.insert(ClvRecord.changeset(%ClvRecord{}, %{
            customer_id: customer_id,
            clv: clv_rounded,
            avg_order_value: Float.round(avg_order_value, 2),
            orders_per_year: Float.round(orders_per_year, 4),
            retention_rate: Float.round(retention_rate, 4),
            churn_probability: Float.round(churn_probability, 4),
            tier: tier,
            order_count: order_count,
            projection_years: @projection_years,
            computed_at: DateTime.utc_now()
          }))

        # --- Queue CRM sync ---
        CrmSync.enqueue_update(%{
          customer_id: customer_id,
          clv: clv_rounded,
          tier: tier
        })

        Logger.info("CLV for customer #{customer_id}: #{clv_rounded} tier=#{tier}")
        {:ok, record}
      end
    end
  end
end
```
