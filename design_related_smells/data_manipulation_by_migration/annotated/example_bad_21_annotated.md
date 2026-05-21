# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `populate_seat_counts/0`
- **Affected functions:** `change/0`, `populate_seat_counts/0`
- **Short explanation:** This migration adds `used_seats` and `available_seats` columns to `plans` (structural change) and then aggregates active subscription member records to compute the current seat usage per plan (data manipulation). Aggregating across multiple related tables and denormalizing the result into a parent record must be handled in a Mix task, not embedded in the migration.

---

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

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration counts active subscription
    # seats from the subscriptions and subscription_members tables, then writes
    # derived counts back to each plan. Computing aggregates across multiple related
    # tables and updating a third table is data manipulation that should be a Mix task.
    populate_seat_counts()
    # VALIDATION: SMELL END
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
