## Metadata

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `Accounts.ProfileManager.process_account_update/1`
- **Affected function(s):** `process_account_update/1`
- **Explanation:** Each of the three clauses of `process_account_update/1` destructures
  eight fields from the `%AccountUpdate{}` struct in the function head (`action`,
  `user_id`, `email`, `full_name`, `role`, `department`, `locale`, `timezone`), but only
  `action` is used in pattern matching. The remaining seven fields are referenced
  exclusively inside the function body. Repeating these extractions across every clause
  head creates significant noise and makes it hard to identify at a glance which bindings
  actually drive clause selection versus which are just convenient body-level aliases.

## Code

```elixir
defmodule Accounts.ProfileManager do
  @moduledoc """
  Manages account lifecycle events: role promotions, profile updates, and deactivations.
  Coordinates between the user store, role policy engine, audit trail, and mailer.
  """

  alias Accounts.{UserStore, Mailer, AuditTrail, RolePolicy}
  require Logger

  @system_actor "system@internal"

  def apply(update_id) do
    with {:ok, update} <- UserStore.fetch_pending_update(update_id),
         {:ok, result} <- process_account_update(update) do
      AuditTrail.commit(update_id, result)
      {:ok, result}
    else
      {:error, :not_found} ->
        Logger.error("Account update not found: #{update_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to apply update #{update_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because process_account_update/1 has three clauses each
  # extracting eight fields from %AccountUpdate{} in the function head (action, user_id,
  # email, full_name, role, department, locale, timezone). Only `action` is used in
  # pattern matching to select the clause. The remaining seven fields (user_id, email,
  # full_name, role, department, locale, timezone) are referenced exclusively inside
  # the function bodies. Repeating all these extractions in every clause head conflates
  # dispatch-relevant bindings with body-only convenience bindings, making it difficult
  # to understand the routing logic without reading each body in full.

  def process_account_update(%AccountUpdate{
        action: action,
        user_id: user_id,
        email: email,
        full_name: full_name,
        role: role,
        department: department,
        locale: locale,
        timezone: timezone
      })
      when action == :promote do
    :ok = RolePolicy.validate_promotion!(role)
    UserStore.update_role(user_id, role, department)

    Mailer.send_promotion_notice(email, %{
      full_name: full_name,
      new_role: role,
      department: department,
      locale: locale
    })

    Logger.info("Promoted user=#{user_id} to role=#{role} in department=#{department}")
    {:ok, %{action: :promoted, user_id: user_id, role: role}}
  end

  def process_account_update(%AccountUpdate{
        action: action,
        user_id: user_id,
        email: email,
        full_name: full_name,
        role: role,
        department: department,
        locale: locale,
        timezone: timezone
      })
      when action == :update_profile do
    UserStore.update_profile(user_id, %{
      full_name: full_name,
      department: department,
      locale: locale,
      timezone: timezone
    })

    Mailer.send_profile_updated(email, %{full_name: full_name, locale: locale})
    Logger.info("Profile updated for user=#{user_id} (dept=#{department}, tz=#{timezone})")
    {:ok, %{action: :profile_updated, user_id: user_id}}
  end

  def process_account_update(%AccountUpdate{
        action: action,
        user_id: user_id,
        email: email,
        full_name: full_name,
        role: role,
        department: department,
        locale: locale,
        timezone: timezone
      })
      when action == :deactivate do
    UserStore.deactivate(user_id, @system_actor)
    UserStore.revoke_all_sessions(user_id)

    Mailer.send_deactivation_notice(email, %{
      full_name: full_name,
      locale: locale,
      former_role: role,
      former_department: department,
      timezone: timezone
    })

    Logger.info("Deactivated user=#{user_id} (role=#{role}, dept=#{department})")
    {:ok, %{action: :deactivated, user_id: user_id}}
  end

  # VALIDATION: SMELL END

  def process_account_update(%AccountUpdate{action: action, user_id: user_id}) do
    Logger.warning("Unhandled account update action=#{action} for user=#{user_id}")
    {:error, {:unknown_action, action}}
  end

  defp log_field_change(user_id, field, old_val, new_val) do
    Logger.debug("user=#{user_id} #{field}: #{inspect(old_val)} -> #{inspect(new_val)}")
  end
end
```
