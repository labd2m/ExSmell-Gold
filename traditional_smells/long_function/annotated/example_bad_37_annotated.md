# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `CRM.CustomerProfileService.update_profile/3`
- **Affected function(s):** `update_profile/3`
- **Short explanation:** `update_profile/3` handles permission checking, field-by-field validation, email-change verification flow, phone normalisation, segment re-evaluation, external CRM sync, change-event publication, and audit logging in a single function that mixes at least eight separate concerns.

---

```elixir
defmodule CRM.CustomerProfileService do
  @moduledoc """
  Manages customer profile updates with permission enforcement,
  field validation, external CRM sync, and event publishing.
  """

  require Logger

  alias CRM.{Customer, Segment, EmailVerification, CRMBridge, EventBus, AuditLog}

  @allowed_roles       [:admin, :sales_rep, :support_agent]
  @phone_regex         ~r/^\+?[0-9\s\-().]{7,20}$/
  @email_change_ttl_hr 24

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `update_profile/3` blends role-
  # based permission enforcement, attribute-level validation (email,
  # phone, tier, company name), e-mail change verification dispatch,
  # phone normalisation, segment re-evaluation, two-way CRM bridge sync,
  # domain-event publishing, and audit-log write into one function body of
  # over 100 lines with no helper delegation.
  def update_profile(customer_id, changes, acting_user) do
    # 1. Permission check
    unless acting_user.role in @allowed_roles do
      {:error, :unauthorised}
    else
      case Customer.get(customer_id) do
        nil ->
          {:error, :customer_not_found}

        %Customer{} = customer ->
          errors = %{}

          # 2. Validate e-mail change
          errors =
            if new_email = changes["email"] do
              cond do
                not String.match?(new_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) ->
                  Map.put(errors, :email, "is not a valid email address")

                Customer.email_taken?(new_email, exclude_id: customer_id) ->
                  Map.put(errors, :email, "is already in use by another customer")

                true ->
                  errors
              end
            else
              errors
            end

          # 3. Validate phone number
          errors =
            if new_phone = changes["phone"] do
              if String.match?(new_phone, @phone_regex) do
                errors
              else
                Map.put(errors, :phone, "is not a valid phone number")
              end
            else
              errors
            end

          # 4. Validate tier value
          errors =
            if new_tier = changes["tier"] do
              valid_tiers = ~w(bronze silver gold platinum)

              if new_tier in valid_tiers do
                errors
              else
                Map.put(errors, :tier, "must be one of: #{Enum.join(valid_tiers, ", ")}")
              end
            else
              errors
            end

          if errors != %{} do
            {:error, {:validation_failed, errors}}
          else
            # 5. Normalise phone (strip spaces and dashes)
            normalised_changes =
              if new_phone = changes["phone"] do
                normalised = String.replace(new_phone, ~r/[\s\-()]/, "")
                Map.put(changes, "phone", normalised)
              else
                changes
              end

            # 6. Handle e-mail change flow
            email_change_pending =
              if new_email = normalised_changes["email"],
                 new_email != customer.email do
                token      = :crypto.strong_rand_bytes(20) |> Base.url_encode64(padding: false)
                expires_at = DateTime.add(DateTime.utc_now(), @email_change_ttl_hr * 3600, :second)

                EmailVerification.insert(%{
                  user_id:    customer_id,
                  token:      token,
                  new_email:  new_email,
                  expires_at: expires_at
                })

                Logger.info("Email change verification sent for customer #{customer_id}")
                true
              else
                false
              end

            # Strip email from direct update if change requires verification
            safe_changes =
              if email_change_pending,
                do:   Map.delete(normalised_changes, "email"),
                else: normalised_changes

            # 7. Persist the update
            case Customer.update(customer_id, safe_changes) do
              {:error, reason} ->
                Logger.error("Profile update failed for #{customer_id}: #{inspect(reason)}")
                {:error, :update_failed}

              {:ok, updated_customer} ->
                # 8. Re-evaluate segments
                new_segments = Segment.evaluate_for_customer(updated_customer)
                Customer.replace_segments(customer_id, new_segments)

                # 9. Sync to external CRM
                Task.start(fn ->
                  case CRMBridge.sync_customer(updated_customer) do
                    {:ok, _}         -> :ok
                    {:error, reason} ->
                      Logger.warning("CRM bridge sync failed for #{customer_id}: #{inspect(reason)}")
                  end
                end)

                # 10. Publish domain event
                EventBus.publish("customer.profile_updated", %{
                  customer_id: customer_id,
                  changed_fields: Map.keys(safe_changes),
                  email_change_pending: email_change_pending,
                  updated_by: acting_user.id
                })

                # 11. Audit log
                AuditLog.insert(%AuditLog{
                  action:     "profile_updated",
                  entity:     "customer",
                  entity_id:  customer_id,
                  actor:      to_string(acting_user.id),
                  metadata:   %{fields: Map.keys(safe_changes)},
                  inserted_at: DateTime.utc_now()
                })

                {:ok, updated_customer}
            end
          end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
