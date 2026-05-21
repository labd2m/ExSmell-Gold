# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_priorities/0`, `derive_priority/1`
- **Short explanation:** In addition to adding a `priority` column, the migration reads every existing support ticket and derives its priority from the `severity` field, writing the result back to the new column. This data derivation and persistence step belongs in a Mix task, not inside `Ecto.Migration`.

---

```elixir
defmodule Support.Repo.Migrations.AddPriorityToTickets do
  use Ecto.Migration

  import Ecto.Query
  alias Support.Repo

  @severity_to_priority %{
    "critical" => 1,
    "high"     => 2,
    "medium"   => 3,
    "low"      => 4,
    "trivial"  => 5
  }

  def change do
    alter table("tickets") do
      add :priority,          :integer, null: true
      add :priority_label,    :string,  null: true
      add :priority_set_at,   :utc_datetime, null: true
    end

    create index("tickets", [:priority])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration reads all existing
    # ticket rows, derives their numeric priority from the severity string,
    # and writes both a numeric priority and a human-readable priority_label
    # back to the database. This is a data transformation step that should
    # be separated into a dedicated Mix task to preserve migration cohesion
    # and allow independent testing of the backfill logic.
    backfill_priorities()
    # VALIDATION: SMELL END
  end

  defp backfill_priorities do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tickets =
      from(t in "tickets",
        where: not is_nil(t.severity),
        select: %{id: t.id, severity: t.severity}
      )
      |> Repo.all()

    Enum.each(tickets, fn %{id: id, severity: severity} ->
      {priority, label} = derive_priority(severity)

      from(t in "tickets", where: t.id == ^id)
      |> Repo.update_all(
        set: [priority: priority, priority_label: label, priority_set_at: now]
      )
    end)
  end

  defp derive_priority(severity) do
    priority = Map.get(@severity_to_priority, severity, 5)

    label =
      case priority do
        1 -> "P1 - Critical"
        2 -> "P2 - High"
        3 -> "P3 - Medium"
        4 -> "P4 - Low"
        _ -> "P5 - Trivial"
      end

    {priority, label}
  end
end
```
