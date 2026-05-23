# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Billing.SubscriptionManager` module — duration/interval parameters |
| **Affected functions** | `create_subscription/3`, `renew/2`, `apply_proration/3`, `calculate_next_billing_date/2` |
| **Short explanation** | Subscription billing periods are represented as a plain `integer` count alongside a separate `String.t()` unit (e.g., `interval = 1`, `interval_unit = "month"`) rather than a `%BillingPeriod{count: pos_integer(), unit: :day | :month | :year}` struct. This splits a cohesive concept into two loose primitives, requires repeated unit validation in every function, and makes it easy to pass the count without its unit or vice-versa. |

```elixir
defmodule Billing.SubscriptionManager do
  @moduledoc """
  Manages recurring subscription lifecycle: creation, renewals,
  proration calculation, and next billing date computation for
  the SaaS billing engine.
  """

  require Logger

  alias Billing.Repo
  alias Billing.Schema.{Subscription, Plan, Customer}

  @valid_interval_units ~w(day week month year)
  @grace_period_days 3

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a billing period is expressed as two
  # separate primitives: an `integer` count and a `String.t()` unit
  # (e.g., interval = 3, interval_unit = "month"), instead of a single
  # %BillingPeriod{count: 3, unit: :month} struct.
  # All functions must pass, validate, and interpret both values together,
  # spreading the pairing logic across every function that touches intervals.

  @spec create_subscription(Customer.t(), Plan.t(), {integer(), String.t()}) ::
          {:ok, Subscription.t()} | {:error, term()}
  def create_subscription(%Customer{} = customer, %Plan{} = plan, {interval, interval_unit})
      when is_integer(interval) and is_binary(interval_unit) do
    with :ok <- validate_interval(interval, interval_unit),
         {:ok, start_date} <- {:ok, Date.utc_today()},
         {:ok, next_billing} <- calculate_next_billing_date(start_date, {interval, interval_unit}) do
      attrs = %{
        customer_id: customer.id,
        plan_id: plan.id,
        interval: interval,
        interval_unit: interval_unit,
        status: :active,
        started_at: start_date,
        next_billing_date: next_billing,
        amount: plan.price
      }

      case %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert() do
        {:ok, sub} ->
          Logger.info("Subscription created: customer=#{customer.id} plan=#{plan.id} every #{interval} #{interval_unit}(s)")
          {:ok, sub}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  @spec renew(Subscription.t(), Date.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def renew(%Subscription{} = sub, as_of_date) do
    interval = sub.interval
    interval_unit = sub.interval_unit

    with {:ok, new_next_billing} <- calculate_next_billing_date(as_of_date, {interval, interval_unit}) do
      sub
      |> Subscription.changeset(%{
        last_billed_at: as_of_date,
        next_billing_date: new_next_billing,
        renewal_count: sub.renewal_count + 1
      })
      |> Repo.update()
    end
  end

  @spec apply_proration(Subscription.t(), Date.t(), {integer(), String.t()}) ::
          {:ok, float()} | {:error, term()}
  def apply_proration(%Subscription{} = sub, change_date, {new_interval, new_unit})
      when is_integer(new_interval) and is_binary(new_unit) do
    with :ok <- validate_interval(new_interval, new_unit) do
      period_days = interval_to_days(sub.interval, sub.interval_unit)
      used_days = Date.diff(change_date, sub.last_billed_at || sub.started_at)
      remaining_days = max(period_days - used_days, 0)
      daily_rate = sub.amount / period_days

      credit = Float.round(remaining_days * daily_rate, 2)

      Logger.info(
        "Proration: #{remaining_days} days remaining on #{sub.interval} #{sub.interval_unit} plan, credit=#{credit}"
      )

      {:ok, credit}
    end
  end

  @spec calculate_next_billing_date(Date.t(), {integer(), String.t()}) ::
          {:ok, Date.t()} | {:error, term()}
  def calculate_next_billing_date(from_date, {interval, interval_unit})
      when is_integer(interval) and is_binary(interval_unit) do
    with :ok <- validate_interval(interval, interval_unit) do
      next =
        case interval_unit do
          "day" -> Date.add(from_date, interval)
          "week" -> Date.add(from_date, interval * 7)
          "month" -> shift_months(from_date, interval)
          "year" -> shift_months(from_date, interval * 12)
        end

      {:ok, next}
    end
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp validate_interval(count, unit) when count <= 0,
    do: {:error, {:invalid_interval_count, count}}

  defp validate_interval(_count, unit) when unit not in @valid_interval_units,
    do: {:error, {:invalid_interval_unit, unit}}

  defp validate_interval(_count, _unit), do: :ok

  defp interval_to_days(count, "day"), do: count
  defp interval_to_days(count, "week"), do: count * 7
  defp interval_to_days(count, "month"), do: count * 30
  defp interval_to_days(count, "year"), do: count * 365

  defp shift_months(date, months) do
    total_months = date.year * 12 + date.month - 1 + months
    new_year = div(total_months, 12)
    new_month = rem(total_months, 12) + 1
    max_day = :calendar.last_day_of_the_month(new_year, new_month)
    %Date{year: new_year, month: new_month, day: min(date.day, max_day)}
  end
end
```
