```elixir
defmodule AuditTrail.Logger do
  @moduledoc """
  Records security-relevant audit events for compliance reporting.
  All events are enriched with actor and session context.
  """

  alias AuditTrail.{Event, Repo, AlertingService}
  alias AuditTrail.Actors.{AdminUser, SystemUser}

  @high_sensitivity_actions [:data_export, :mfa_disable, :role_escalation, :impersonation]


  @doc """
  Logs a data export action, including what was exported and who requested it.
  Triggers a security alert for large exports.
  """
  def log_data_export(actor, session, %{record_count: count, resource: resource} = export_meta) do
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


  @doc """
  Logs a workspace or account settings change, including the before/after
  diff of the changed fields.
  """
  def log_settings_change(actor, session, %{setting: setting, before: before_val, after: after_val}) do
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
