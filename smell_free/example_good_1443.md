```elixir
defmodule Billing.Subscriptions.PlanUpgrader do
  @moduledoc """
  Handles plan upgrade logic for active subscriptions.
  Applies proration calculations and delegates side effects to injected adapters.
  """

  alias Billing.Subscriptions.{Plan, Subscription, Proration}

  @type adapter :: module()
  @type upgrade_result :: {:ok, Subscription.t()} | {:error, atom() | String.t()}

  @doc """
  Upgrades `subscription` to `target_plan`, applying proration and invoicing.

  Accepts an optional `:adapter` keyword option to override the default billing adapter.
  """
  @spec upgrade(Subscription.t(), Plan.t(), keyword()) :: upgrade_result()
  def upgrade(%Subscription{} = sub, %Plan{} = target_plan, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Billing.Adapters.Stripe)

    with :ok <- validate_upgrade_eligibility(sub, target_plan),
         {:ok, proration} <- Proration.calculate(sub, target_plan),
         {:ok, invoice} <- adapter.create_invoice(sub.customer_id, proration),
         {:ok, updated_sub} <- apply_plan_change(sub, target_plan, invoice) do
      {:ok, updated_sub}
    end
  end

  defp validate_upgrade_eligibility(%Subscription{status: :active, plan: current}, target) do
    cond do
      current.id == target.id -> {:error, :already_on_plan}
      target.tier <= current.tier -> {:error, :not_an_upgrade}
      true -> :ok
    end
  end

  defp validate_upgrade_eligibility(%Subscription{status: status}, _target) do
    {:error, {:ineligible_status, status}}
  end

  defp apply_plan_change(sub, plan, invoice) do
    updated = %{sub | plan: plan, upgraded_at: DateTime.utc_now(), last_invoice_id: invoice.id}
    {:ok, updated}
  end
end

defmodule Billing.Subscriptions.Proration do
  @moduledoc """
  Computes prorated credit and debit amounts when switching subscription plans mid-cycle.
  """

  alias Billing.Subscriptions.{Plan, Subscription}

  @type proration_result :: %{
          credit_cents: non_neg_integer(),
          debit_cents: non_neg_integer(),
          net_cents: integer()
        }

  @doc """
  Calculates prorated amounts for a mid-cycle plan change.
  """
  @spec calculate(Subscription.t(), Plan.t()) :: {:ok, proration_result()} | {:error, String.t()}
  def calculate(%Subscription{} = sub, %Plan{} = target) do
    with {:ok, days_remaining} <- remaining_days(sub),
         {:ok, cycle_days} <- cycle_length(sub) do
      credit = prorate(sub.plan.monthly_cents, days_remaining, cycle_days)
      debit = prorate(target.monthly_cents, days_remaining, cycle_days)
      net = debit - credit
      {:ok, %{credit_cents: credit, debit_cents: debit, net_cents: net}}
    end
  end

  defp remaining_days(%Subscription{current_period_end: period_end}) do
    today = Date.utc_today()
    end_date = DateTime.to_date(period_end)
    days = Date.diff(end_date, today)

    if days >= 0 do
      {:ok, days}
    else
      {:error, "subscription period has already ended"}
    end
  end

  defp cycle_length(%Subscription{current_period_start: start, current_period_end: period_end}) do
    days = Date.diff(DateTime.to_date(period_end), DateTime.to_date(start))

    if days > 0 do
      {:ok, days}
    else
      {:error, "invalid subscription cycle"}
    end
  end

  defp prorate(monthly_cents, days_remaining, cycle_days) do
    round(monthly_cents * days_remaining / cycle_days)
  end
end
```
