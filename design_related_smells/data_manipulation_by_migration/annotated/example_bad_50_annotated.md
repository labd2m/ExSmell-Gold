# Code Smell Example 50

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `classify_existing_events/0`
- **Short explanation:** The migration adds a `severity` column to `audit_events` (structural change) and then reads every existing event, derives a severity label from its `event_type`, and writes it back (data manipulation), mixing classification business logic with schema evolution inside one migration module.

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration goes beyond adding the
    # severity column (DDL) and also iterates over every existing audit_event
    # row, applies classification logic based on event_type, and persists the
    # derived severity value (DML). This data-enrichment logic belongs in a
    # separate Mix task, keeping the migration focused solely on schema changes.
    classify_existing_events()
    # VALIDATION: SMELL END
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
end
```
