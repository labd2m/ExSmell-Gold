```elixir
defmodule SaaS.Repo.Migrations.AddSeatCountsToPlans do
  use Ecto.Migration

  import Ecto.Query
  alias SaaS.Repo

  def change do
    alter table("plans") do
      add :max_seats,       :integer, null: true
      add :used_seats,      :integer, default: 0, null: false
      add :available_seats, :integer, null: true
    end

    create index("plans", [:used_seats])
    create index("plans", [:available_seats])

    flush()

    populate_seat_counts()
  end

  defp populate_seat_counts do
    plan_ids =
      from(p in "plans", select: p.id)
      |> Repo.all()

    Enum.each(plan_ids, fn plan_id ->
      used =
        from(sm in "subscription_members",
          join: s in "subscriptions", on: s.id == sm.subscription_id,
          where: s.plan_id == ^plan_id and s.status == "active",
          select: count(sm.id)
        )
        |> Repo.one()
        |> Kernel.||(0)

      max_seats =
        from(p in "plans",
          where: p.id == ^plan_id,
          select: p.max_seats
        )
        |> Repo.one()

      available =
        case max_seats do
          nil -> nil
          max -> max(max - used, 0)
        end

      from(p in "plans", where: p.id == ^plan_id)
      |> Repo.update_all(
        set: [
          used_seats:      used,
          available_seats: available
        ]
      )
    end)
  end
end
```
