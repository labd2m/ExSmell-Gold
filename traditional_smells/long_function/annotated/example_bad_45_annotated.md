# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Telecom.SubscriptionManager.change_plan/3`
- **Affected function(s):** `change_plan/3`
- **Short explanation:** `change_plan/3` handles plan-compatibility checking, proration calculation, add-on conflict resolution, billing-cycle adjustment, carrier-provisioning update, CRM sync, invoice generation, and customer notification all inside a single monolithic function body.

---

```elixir
defmodule Telecom.SubscriptionManager do
  @moduledoc """
  Manages mobile subscription plan changes including
  proration, add-on compatibility, and carrier provisioning.
  """

  require Logger

  alias Telecom.{
    Subscription, Plan, AddOn, Proration,
    BillingCycle, CarrierAPI, CRMSync,
    Invoice, Mailer
  }

  @prorate_min_days 3

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `change_plan/3` concatenates plan
  # compatibility validation, add-on conflict resolution, proration
  # computation, billing-cycle recalculation, carrier provisioning,
  # CRM synchronisation, invoice creation, and customer notification
  # into one function exceeding 110 lines without any helper extraction,
  # making each distinct concern difficult to test or modify in isolation.
  def change_plan(subscription_id, new_plan_id, opts \\ []) do
    effective   = Keyword.get(opts, :effective, :immediate)
    requested_by = Keyword.get(opts, :requested_by, "customer_portal")

    case Subscription.get(subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      %Subscription{status: :cancelled} ->
        {:error, :subscription_cancelled}

      %Subscription{} = sub ->
        # 1. Load new plan
        case Plan.get(new_plan_id) do
          nil ->
            {:error, :plan_not_found}

          %Plan{available: false} ->
            {:error, :plan_not_available}

          %Plan{} = new_plan ->
            current_plan = Plan.get(sub.plan_id)

            # 2. Prevent same-plan change
            if new_plan.id == current_plan.id do
              {:error, :same_plan}
            else
              # 3. Check plan-level compatibility (e.g. cannot downgrade postpaid → prepaid)
              case Plan.compatible_transition?(current_plan, new_plan) do
                {:error, reason} ->
                  {:error, {:incompatible_transition, reason}}

                :ok ->
                  # 4. Resolve add-on conflicts with new plan
                  active_addons = AddOn.list_for_subscription(sub.id)

                  conflicting_addons =
                    Enum.filter(active_addons, fn addon ->
                      not AddOn.compatible_with_plan?(addon, new_plan)
                    end)

                  # Remove conflicting add-ons
                  Enum.each(conflicting_addons, fn addon ->
                    Logger.info("Removing incompatible add-on #{addon.id} due to plan change")
                    AddOn.deactivate(addon.id)
                  end)

                  # 5. Calculate proration
                  today = Date.utc_today()
                  days_remaining = Date.diff(sub.cycle_end_date, today)

                  {credit_cents, charge_cents} =
                    if days_remaining >= @prorate_min_days do
                      Proration.calculate(%{
                        current_plan:  current_plan,
                        new_plan:      new_plan,
                        days_remaining: days_remaining,
                        cycle_days:    BillingCycle.days_in_cycle(sub.billing_cycle)
                      })
                    else
                      {0, 0}
                    end

                  # 6. Determine effective date
                  effective_date =
                    case effective do
                      :immediate     -> today
                      :next_cycle    -> sub.cycle_end_date
                      %Date{} = date -> date
                    end

                  # 7. Persist subscription update
                  update_attrs = %{
                    plan_id:         new_plan.id,
                    status:          if(effective == :immediate, do: :active, else: sub.status),
                    pending_plan_id: if(effective == :next_cycle, do: new_plan.id, else: nil),
                    plan_change_at:  effective_date,
                    changed_by:      requested_by,
                    updated_at:      DateTime.utc_now()
                  }

                  case Subscription.update(sub.id, update_attrs) do
                    {:error, reason} ->
                      Logger.error("Subscription update failed: #{inspect(reason)}")
                      {:error, :update_failed}

                    {:ok, updated_sub} ->
                      # 8. Provision change on carrier network
                      if effective == :immediate do
                        case CarrierAPI.provision_plan_change(%{
                          msisdn:    sub.msisdn,
                          old_plan:  current_plan.carrier_code,
                          new_plan:  new_plan.carrier_code
                        }) do
                          {:ok, _}         -> Logger.info("Carrier provisioned for #{sub.msisdn}")
                          {:error, reason} ->
                            Logger.error("Carrier provisioning failed: #{inspect(reason)}")
                        end
                      end

                      # 9. Sync to CRM
                      Task.start(fn ->
                        CRMSync.update_subscription(%{
                          customer_id:  sub.customer_id,
                          plan_name:    new_plan.name,
                          effective_at: effective_date
                        })
                      end)

                      # 10. Generate adjustment invoice if proration applies
                      if credit_cents > 0 or charge_cents > 0 do
                        Invoice.create(%{
                          subscription_id: sub.id,
                          customer_id:     sub.customer_id,
                          type:            :proration,
                          credit_cents:    credit_cents,
                          charge_cents:    charge_cents,
                          description:     "Plan change: #{current_plan.name} → #{new_plan.name}",
                          issued_at:       DateTime.utc_now()
                        })
                      end

                      # 11. Notify the customer
                      effective_label = if effective == :immediate, do: "immediately", else: "on #{effective_date}"

                      email_body = """
                      Hi #{sub.customer_name},

                      Your subscription plan has been changed #{effective_label}.

                      Previous plan : #{current_plan.name}
                      New plan      : #{new_plan.name}
                      Effective     : #{effective_date}
                      #{if credit_cents > 0, do: "Credit applied: $#{Float.round(credit_cents / 100, 2)}", else: ""}
                      #{if length(conflicting_addons) > 0, do: "Note: #{length(conflicting_addons)} add-on(s) were removed as they are incompatible with your new plan.", else: ""}

                      Questions? Contact support at support@example.com.
                      """

                      case Mailer.send_email(sub.customer_email, "Your plan has changed", email_body) do
                        {:ok, _}         -> :ok
                        {:error, reason} -> Logger.warning("Customer email failed: #{inspect(reason)}")
                      end

                      Logger.info("Plan change complete for subscription #{sub.id}")
                      {:ok, updated_sub}
                  end
              end
            end
        end
    end
  end
  # VALIDATION: SMELL END
end
```
