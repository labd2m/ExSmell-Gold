# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `SubscriptionProration.compute/3`, where `days_remaining` is used in division
- **Affected function(s):** `compute/3`
- **Short explanation:** The `days_remaining` value is derived from `Date.diff/2` (which always returns an integer) but then the function also accepts an externally-supplied `days_remaining` override via opts. That override is used directly in the expression `days_remaining / cycle_days` without any type validation. Passing a string override such as `"15"` causes an `ArithmeticError` inside the division, far from the public `compute/3` boundary where the bad value entered.

```elixir
defmodule MyApp.Subscriptions.SubscriptionProration do
  @moduledoc """
  Computes prorated charges and credits for mid-cycle subscription changes
  including plan upgrades, downgrades, seat adjustments, and cancellations.
  """

  require Logger

  alias MyApp.Subscriptions.{SubscriptionRecord, PlanCatalog, CreditLedger, ProrationRecord}
  alias MyApp.Billing.InvoiceQueue

  @rounding_precision 4
  @minimum_proration_amount 0.01
  @supported_change_types [:upgrade, :downgrade, :seat_change, :cancellation]

  @type proration_opts :: [
          change_type: atom(),
          effective_date: Date.t(),
          days_remaining_override: term() | nil,
          issue_credit: boolean()
        ]

  @spec compute(String.t(), String.t(), proration_opts()) ::
          {:ok, map()} | {:error, atom()}
  def compute(subscription_id, new_plan_id, opts \\ []) do
    change_type = Keyword.get(opts, :change_type, :upgrade)
    effective_date = Keyword.get(opts, :effective_date, Date.utc_today())
    issue_credit = Keyword.get(opts, :issue_credit, true)

    with :ok <- validate_change_type(change_type),
         {:ok, subscription} <- SubscriptionRecord.fetch(subscription_id),
         {:ok, current_plan} <- PlanCatalog.fetch(subscription.plan_id),
         {:ok, new_plan} <- PlanCatalog.fetch(new_plan_id) do

      cycle_days = Date.diff(subscription.current_period_end, subscription.current_period_start)

      days_remaining =
        case Keyword.get(opts, :days_remaining_override) do
          nil -> Date.diff(subscription.current_period_end, effective_date)
          override -> override
        end

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `days_remaining` may come from the
      # VALIDATION: `days_remaining_override` option without any type validation.
      # VALIDATION: When a caller passes a string like "15" as the override,
      # VALIDATION: `days_remaining / cycle_days` raises an ArithmeticError
      # VALIDATION: deep inside Erlang's arithmetic operators, giving no indication
      # VALIDATION: that the bad value entered through the opts at this boundary.
      proration_factor = Float.round(days_remaining / cycle_days, @rounding_precision)
      # VALIDATION: SMELL END

      current_daily_rate = current_plan.monthly_price / cycle_days
      new_daily_rate = new_plan.monthly_price / cycle_days

      unused_credit = Float.round(current_daily_rate * days_remaining, @rounding_precision)
      new_charge = Float.round(new_daily_rate * days_remaining, @rounding_precision)
      net_amount = Float.round(new_charge - unused_credit, @rounding_precision)

      result = %{
        subscription_id: subscription_id,
        current_plan_id: subscription.plan_id,
        new_plan_id: new_plan_id,
        change_type: change_type,
        effective_date: effective_date,
        cycle_days: cycle_days,
        days_remaining: days_remaining,
        proration_factor: proration_factor,
        unused_credit: unused_credit,
        new_charge: new_charge,
        net_amount: net_amount,
        currency: current_plan.currency
      }

      with :ok <- maybe_issue_credit(subscription_id, unused_credit, issue_credit),
           {:ok, record} <- ProrationRecord.create(result) do
        if abs(net_amount) >= @minimum_proration_amount do
          InvoiceQueue.enqueue_proration(subscription_id, net_amount, current_plan.currency)
        end

        Logger.info(
          "Proration computed: subscription=#{subscription_id} " <>
            "net=#{net_amount} factor=#{proration_factor}"
        )

        {:ok, record}
      end
    end
  end

  @spec preview(String.t(), String.t(), proration_opts()) ::
          {:ok, map()} | {:error, atom()}
  def preview(subscription_id, new_plan_id, opts \\ []) do
    opts_without_credit = Keyword.put(opts, :issue_credit, false)

    case compute(subscription_id, new_plan_id, opts_without_credit) do
      {:ok, result} -> {:ok, Map.put(result, :preview_only, true)}
      err -> err
    end
  end

  @spec list_for_subscription(String.t()) :: {:ok, [map()]} | {:error, atom()}
  def list_for_subscription(subscription_id) do
    ProrationRecord.list(subscription_id)
  end

  # Private helpers

  defp validate_change_type(type) when type in @supported_change_types, do: :ok
  defp validate_change_type(_), do: {:error, :invalid_change_type}

  defp maybe_issue_credit(_subscription_id, _amount, false), do: :ok

  defp maybe_issue_credit(subscription_id, amount, true) when amount > 0 do
    CreditLedger.issue(subscription_id, amount, "Proration credit for plan change")
  end

  defp maybe_issue_credit(_subscription_id, _amount, true), do: :ok
end
```
