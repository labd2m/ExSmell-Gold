```elixir
defmodule Subscriptions.Manager do
  @moduledoc """
  Handles SaaS subscription provisioning, trial setup, coupon application,
  and renewal configuration.
  """

  require Logger

  alias Subscriptions.Repo
  alias Subscriptions.Schemas.Subscription
  alias Subscriptions.PlanCatalog
  alias Subscriptions.CouponService
  alias Subscriptions.PaymentGateway
  alias Subscriptions.Mailer

  @valid_cycles ~w(monthly annual)
  @supported_currencies ~w(USD EUR GBP BRL)
  @max_trial_days 60

  def create_subscription(
        account_id,
        owner_email,
        plan_id,
        billing_cycle,
        seats,
        payment_method_id,
        currency,
        trial_days,
        coupon_code,
        auto_renew
      ) do
    with {:ok, plan} <- PlanCatalog.fetch(plan_id),
         :ok <- validate_billing_cycle(billing_cycle),
         :ok <- validate_seats(seats, plan),
         :ok <- validate_currency(currency),
         :ok <- validate_trial_days(trial_days) do
      discount_pct = resolve_coupon(coupon_code, plan_id)
      unit_price = plan_price(plan, billing_cycle)
      total = unit_price * seats * (1 - discount_pct / 100)

      trial_end =
        if trial_days > 0 do
          Date.add(Date.utc_today(), trial_days)
        else
          nil
        end

      billing_start =
        if trial_end, do: trial_end, else: Date.utc_today()

      sub_attrs = %{
        account_id: account_id,
        owner_email: owner_email,
        plan_id: plan_id,
        plan_name: plan.name,
        billing_cycle: billing_cycle,
        seats: seats,
        payment_method_id: payment_method_id,
        currency: currency,
        unit_price: unit_price,
        discount_percent: discount_pct,
        total_amount: total,
        coupon_code: coupon_code,
        trial_ends_on: trial_end,
        billing_starts_on: billing_start,
        auto_renew: auto_renew,
        status: if(trial_days > 0, do: :trialing, else: :active),
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Subscription.changeset(%Subscription{}, sub_attrs)) do
        {:ok, sub} ->
          if trial_end == nil do
            PaymentGateway.setup_recurring(payment_method_id, total, currency, billing_cycle)
          end

          Mailer.send_subscription_confirmation(owner_email, sub)
          Logger.info("Subscription #{sub.id} created for account #{account_id}")
          {:ok, sub}

        {:error, changeset} ->
          Logger.error("Subscription creation failed: #{inspect(changeset.errors)}")
          {:error, :subscription_failed}
      end
    end
  end

  defp validate_billing_cycle(c) when c in @valid_cycles, do: :ok
  defp validate_billing_cycle(c), do: {:error, {:unknown_billing_cycle, c}}

  defp validate_seats(seats, plan) do
    cond do
      not is_integer(seats) or seats < 1 -> {:error, :invalid_seats}
      plan.max_seats && seats > plan.max_seats -> {:error, :exceeds_plan_seat_limit}
      true -> :ok
    end
  end

  defp validate_currency(c) when c in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, {:unsupported_currency, c}}

  defp validate_trial_days(d) when is_integer(d) and d >= 0 and d <= @max_trial_days, do: :ok
  defp validate_trial_days(_), do: {:error, :invalid_trial_days}

  defp resolve_coupon(nil, _), do: 0

  defp resolve_coupon(code, plan_id) do
    case CouponService.apply(code, plan_id) do
      {:ok, pct} -> pct
      _ -> 0
    end
  end

  defp plan_price(plan, "monthly"), do: plan.monthly_price
  defp plan_price(plan, "annual"), do: plan.annual_price
end
```
