```elixir
defmodule Support.Repo.Migrations.AddPriorityScoreToTickets do
  use Ecto.Migration


  import Ecto.Query
  alias Support.Helpdesk.Ticket
  alias Support.Repo

  @base_score_by_type %{
    "billing"  => 80,
    "outage"   => 100,
    "feature"  => 30,
    "general"  => 50
  }

  def change do
    alter table("tickets") do
      add :priority_score, :integer, null: false, default: 50
      add :priority_label, :string, null: false, default: "normal"
    end

    create index("tickets", [:priority_score])
    create index("tickets", [:priority_label])

    flush()

    seed_priority_scores()
  end

  defp seed_priority_scores do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(t in Ticket,
      where: t.status in ["open", "in_progress"],
      select: %{id: t.id, ticket_type: t.ticket_type, inserted_at: t.inserted_at}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, ticket_type: type, inserted_at: created} ->
      age_hours = DateTime.diff(DateTime.utc_now(), DateTime.from_naive!(created, "Etc/UTC"), :hour)
      {score, label} = compute_priority(type, age_hours)

      from(t in Ticket, where: t.id == ^id)
      |> Repo.update_all(set: [priority_score: score, priority_label: label])
    end)
  end

  defp compute_priority(type, age_hours) do
    base  = Map.get(@base_score_by_type, type, 50)
    score = min(base + div(age_hours, 2), 100)

    label =
      cond do
        score >= 90 -> "critical"
        score >= 70 -> "high"
        score >= 40 -> "normal"
        true        -> "low"
      end

    {score, label}
  end

end
```
