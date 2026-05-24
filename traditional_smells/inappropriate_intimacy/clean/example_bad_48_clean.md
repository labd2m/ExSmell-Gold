```elixir
defmodule Billing.SubscriptionUpgrader do
  @moduledoc """
  Handles mid-cycle subscription upgrades between billing plans.
  Computes prorated charges and applies them to the customer's account.
  """

  require Logger

  alias Billing.{Subscription, Plan, Customer, ProrationLedger, UpgradeRecord}
  alias Payments.ChargeGateway
  alias Repo

  @proration_precision 6

  def upgrade(subscription_id, new_plan_id, opts \\ []) do
    with {:ok, sub} <- Subscription.fetch(subscription_id),
         {:ok, old_plan} <- Plan.fetch(sub.plan_id),
         {:ok, new_plan} <- Plan.fetch(new_plan_id),
         {:ok, customer} <- Customer.fetch(sub.customer_id) do
      validate_and_apply(sub, old_plan, new_plan, customer, opts)
    end
  end

  defp validate_and_apply(sub, old_plan, new_plan, customer, opts) do
    cond do
      new_plan.price_cents <= old_plan.price_cents ->
        {:error, :not_an_upgrade}

      old_plan.billing_interval != new_plan.billing_interval ->
        {:error, :interval_mismatch}

      is_nil(customer.payment_method_id) ->
        {:error, :no_payment_method}

      true ->
        seat_count = Subscription.current_seat_count(sub)

        if seat_count > new_plan.max_seats do
          {:error, {:seat_limit_exceeded, new_plan.max_seats}}
        else
          missing_features =
            Enum.reject(old_plan.features, fn f -> f in new_plan.features end)

          if length(missing_features) > 0 do
            Logger.warning("Upgrade would remove features: #{inspect(missing_features)}")
          end

          proration = compute_proration(sub, old_plan, new_plan)

          final_charge =
            if customer.tax_exempt do
              proration
            else
              tax_rate = Customer.applicable_tax_rate(customer)
              round(proration * (1 + tax_rate))
            end

          apply_upgrade(sub, new_plan, customer, final_charge, proration, opts)
        end
    end
  end

  defp compute_proration(sub, old_plan, new_plan) do
    today = Date.utc_today()
    days_remaining = Date.diff(sub.current_period_end, today)
    total_days = Date.diff(sub.current_period_end, sub.current_period_start)

    old_daily = old_plan.price_cents / total_days
    new_daily = new_plan.price_cents / total_days

    delta_daily = new_daily - old_daily
    prorated = delta_daily * days_remaining

    prorated
    |> Float.round(@proration_precision)
    |> round()
    |> max(0)
  end

  defp apply_upgrade(sub, new_plan, customer, charge_cents, proration_cents, opts) do
    Repo.transaction(fn ->
      {:ok, updated_sub} =
        sub
        |> Subscription.changeset(%{
          plan_id: new_plan.id,
          upgraded_at: DateTime.utc_now()
        })
        |> Repo.update()

      {:ok, proration_entry} =
        %ProrationLedger{
          subscription_id: sub.id,
          old_plan_id: sub.plan_id,
          new_plan_id: new_plan.id,
          amount_cents: proration_cents,
          created_at: DateTime.utc_now()
        }
        |> Repo.insert()

      charge_result =
        if opts[:defer_charge] do
          {:ok, :deferred}
        else
          ChargeGateway.charge(customer.payment_method_id, charge_cents, %{
            description: "Plan upgrade proration",
            metadata: %{subscription_id: sub.id, proration_id: proration_entry.id}
          })
        end

      case charge_result do
        {:ok, _} ->
          %UpgradeRecord{
            subscription_id: sub.id,
            old_plan_id: sub.plan_id,
            new_plan_id: new_plan.id,
            charge_cents: charge_cents,
            status: :completed
          }
          |> Repo.insert!()

          Logger.info("Subscription #{sub.id} upgraded to plan #{new_plan.id}")
          updated_sub

        {:error, reason} ->
          Repo.rollback({:charge_failed, reason})
      end
    end)
  end
end
```
