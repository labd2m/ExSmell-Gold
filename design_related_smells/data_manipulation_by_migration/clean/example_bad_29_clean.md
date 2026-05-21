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

    backfill_priorities()
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
