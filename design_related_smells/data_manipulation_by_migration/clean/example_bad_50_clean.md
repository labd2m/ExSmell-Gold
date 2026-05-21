```elixir
defmodule AuditService.Repo.Migrations.AddSeverityToAuditEvents do
  use Ecto.Migration

  import Ecto.Query
  alias AuditService.Repo

  @critical_types   ["account_deleted", "permission_escalated", "mfa_disabled"]
  @high_types       ["password_changed", "api_key_rotated", "bulk_export"]
  @medium_types     ["login_failed", "settings_updated", "email_changed"]

  def change do
    alter table("audit_events") do
      add :severity,            :string, null: true
      add :severity_set_at,     :utc_datetime, null: true
    end

    create index("audit_events", [:severity])
    create index("audit_events", [:severity, :inserted_at])

    flush()

    classify_existing_events()
  end

  defp classify_existing_events do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in "audit_events",
      where: is_nil(e.severity),
      select: {e.id, e.event_type}
    )
    |> Repo.all()
    |> Enum.each(fn {id, event_type} ->
      severity = derive_severity(event_type)

      from(e in "audit_events",
        where: e.id == ^id,
        update: [set: [severity: ^severity, severity_set_at: ^now]]
      )
      |> Repo.update_all([])
    end)
  end

  defp derive_severity(event_type) do
    cond do
      event_type in @critical_types -> "critical"
      event_type in @high_types     -> "high"
      event_type in @medium_types   -> "medium"
      true                          -> "low"
    end
  end
end```
