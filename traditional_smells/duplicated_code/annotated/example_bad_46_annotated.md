# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `AuditTrail.Logger.log_data_export/3` and `AuditTrail.Logger.log_settings_change/3` |
| **Affected functions** | `log_data_export/3`, `log_settings_change/3` |
| **Short explanation** | Both functions independently assemble the same base event metadata map (actor details, session info, IP address, user-agent, timestamp). If a new field is required in every audit event—e.g., a geographic region—it must be added in both functions. |

```elixir
defmodule AuditTrail.Logger do
  @moduledoc """
  Records security-relevant audit events for compliance reporting.
  All events are enriched with actor and session context.
  """

  alias AuditTrail.{Event, Repo, AlertingService}
  alias AuditTrail.Actors.{AdminUser, SystemUser}

  @high_sensitivity_actions [:data_export, :mfa_disable, :role_escalation, :impersonation]

  # ---------------------------------------------------------------------------
  # Data export audit
  # ---------------------------------------------------------------------------

  @doc """
  Logs a data export action, including what was exported and who requested it.
  Triggers a security alert for large exports.
  """
  def log_data_export(actor, session, %{record_count: count, resource: resource} = export_meta) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the base event metadata assembly
    # (actor_id, actor_type, session_id, ip, user_agent, occurred_at) is
    # copy-pasted verbatim into log_settings_change/3. Any new mandatory
    # field must be inserted in both functions.
    actor_type =
      case actor do
        %AdminUser{}  -> :admin
        %SystemUser{} -> :system
        _             -> :user
      end

    base_event = %{
      actor_id:   actor.id,
      actor_email: actor.email,
      actor_type: actor_type,
      session_id: session.id,
      ip_address: session.remote_ip,
      user_agent: session.user_agent,
      occurred_at: DateTime.utc_now()
    }
    # VALIDATION: SMELL END

    event = Event.new(
      Map.merge(base_event, %{
        action:       :data_export,
        sensitivity:  :high,
        resource:     resource,
        record_count: count,
        metadata:     export_meta
      })
    )

    {:ok, saved} = Repo.insert_event(event)

    if count > 10_000 do
      AlertingService.notify_security_team(:large_data_export, saved)
    end

    {:ok, saved}
  end

  # ---------------------------------------------------------------------------
  # Settings change audit
  # ---------------------------------------------------------------------------

  @doc """
  Logs a workspace or account settings change, including the before/after
  diff of the changed fields.
  """
  def log_settings_change(actor, session, %{setting: setting, before: before_val, after: after_val}) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the same base_event assembly from
    # log_data_export/3 is duplicated here. Both copies must be updated in
    # lockstep when the event schema changes.
    actor_type =
      case actor do
        %AdminUser{}  -> :admin
        %SystemUser{} -> :system
        _             -> :user
      end

    base_event = %{
      actor_id:    actor.id,
      actor_email: actor.email,
      actor_type:  actor_type,
      session_id:  session.id,
      ip_address:  session.remote_ip,
      user_agent:  session.user_agent,
      occurred_at: DateTime.utc_now()
    }
    # VALIDATION: SMELL END

    sensitivity = if setting in @high_sensitivity_actions, do: :high, else: :medium

    event = Event.new(
      Map.merge(base_event, %{
        action:      :settings_change,
        sensitivity: sensitivity,
        setting:     setting,
        before:      before_val,
        after:       after_val
      })
    )

    {:ok, saved} = Repo.insert_event(event)

    if sensitivity == :high do
      AlertingService.notify_security_team(:sensitive_setting_changed, saved)
    end

    {:ok, saved}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp redact_pii(%{email: email} = map) do
    Map.put(map, :email, redact_email(email))
  end
  defp redact_pii(map), do: map

  defp redact_email(email) do
    [local | _] = String.split(email, "@")
    masked = String.slice(local, 0, 2) <> "***"
    "#{masked}@[redacted]"
  end
end
```
