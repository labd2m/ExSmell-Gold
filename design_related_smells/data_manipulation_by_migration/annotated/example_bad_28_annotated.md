# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `archive_old_orders/0`
- **Short explanation:** The migration adds an `archived_at` column to `orders` and then applies a business rule — marking orders older than two years as archived — directly inside the migration. Applying conditional business logic to existing rows is data manipulation that must not reside in a migration module.

---

```elixir
defmodule Fulfillment.Repo.Migrations.AddArchivedAtToOrders do
  use Ecto.Migration

  import Ecto.Query
  alias Fulfillment.Repo

  @archive_threshold_days 730

  def change do
    alter table("orders") do
      add :archived_at, :utc_datetime, null: true
      add :is_archived,  :boolean, default: false, null: false
    end

    create index("orders", [:is_archived])
    create index("orders", [:archived_at])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration applies a business
    # rule (archiving orders older than 730 days) by updating rows in the
    # database immediately after the structural change. Deciding which rows
    # to mark as archived and writing that decision back to the table is pure
    # data manipulation that reduces cohesion and testability of the migration.
    archive_old_orders()
    # VALIDATION: SMELL END
  end

  defp archive_old_orders do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@archive_threshold_days * 86_400, :second)
      |> DateTime.truncate(:second)

    from(o in "orders",
      where: o.inserted_at < ^cutoff and o.status == "completed",
      update: [set: [is_archived: true, archived_at: ^cutoff]]
    )
    |> Repo.update_all([])
  end
end
```
