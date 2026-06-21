# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` function and private helpers `backfill_order_status/0`, `classify_status/1`
- **Affected functions:** `change/0`, `backfill_order_status/0`, `classify_status/1`
- **Short explanation:** This migration both alters the `orders` table (structural change) and iterates over existing rows to populate the new `normalized_status` column (data manipulation). These two responsibilities should live in separate modules: the migration for schema changes and a Mix task for data backfilling.

---

```elixir
defmodule Commerce.Repo.Migrations.AddNormalizedStatusToOrders do
  use Ecto.Migration

  import Ecto.Query
  alias Commerce.Repo

  @legacy_status_map %{
    "new"           => "pending",
    "in_process"    => "processing",
    "sent"          => "shipped",
    "done"          => "completed",
    "voided"        => "cancelled",
    "ret"           => "returned"
  }

  def change do
    alter table("orders") do
      add :normalized_status, :string, null: true
    end

    create index("orders", [:normalized_status])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration performs data manipulation
    # (reading and updating existing rows) in addition to the structural schema change
    # (adding the normalized_status column). Migrations should only modify schema structure.
    backfill_order_status()
    # VALIDATION: SMELL END
  end

  defp backfill_order_status do
    batch_size = 500

    from(o in "orders",
      where: is_nil(o.normalized_status),
      select: %{id: o.id, legacy_status: o.status},
      limit: ^batch_size
    )
    |> Repo.all()
    |> case do
      [] ->
        :ok

      rows ->
        rows
        |> Enum.each(fn %{id: id, legacy_status: legacy} ->
          new_status = classify_status(legacy)

          from(o in "orders", where: o.id == ^id)
          |> Repo.update_all(set: [normalized_status: new_status])
        end)

        backfill_order_status()
    end
  end

  defp classify_status(legacy_status) when is_binary(legacy_status) do
    Map.get(@legacy_status_map, String.downcase(legacy_status), "unknown")
  end

  defp classify_status(_), do: "unknown"
end
```
