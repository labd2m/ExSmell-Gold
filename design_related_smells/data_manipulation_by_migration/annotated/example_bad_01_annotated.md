# Annotated Bad Example 01

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddFulfillmentStatusToOrders`
- **Affected function(s):** `change/0`, `backfill_fulfillment_status/0`, `resolve_status/1`
- **Short explanation:** The migration module both alters the `orders` table schema (adding a new column) and performs data manipulation (reading and updating existing rows). These responsibilities should be separated: the schema change belongs in the migration, and the data backfill belongs in a dedicated Mix task.

---

## Code

```elixir
defmodule Commerce.Repo.Migrations.AddFulfillmentStatusToOrders do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration module is responsible for both
  # structural changes (adding the :fulfillment_status column) and data manipulation
  # (reading existing orders and updating their fulfillment_status based on business logic).
  # These two responsibilities should live in separate modules.

  import Ecto.Query
  alias Commerce.Orders.Order
  alias Commerce.Repo

  @fulfillment_terminal_states ~w(shipped delivered cancelled)

  def change do
    alter table("orders") do
      add :fulfillment_status, :string, null: false, default: "pending"
      add :fulfillment_updated_at, :utc_datetime
    end

    create index("orders", [:fulfillment_status])
    create index("orders", [:fulfillment_updated_at])

    flush()

    backfill_fulfillment_status()
  end

  defp backfill_fulfillment_status do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(o in Order,
      where: o.status in @fulfillment_terminal_states,
      select: %{id: o.id, status: o.status}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, status: status} ->
      fulfillment = resolve_status(status)

      from(o in Order, where: o.id == ^id)
      |> Repo.update_all(
        set: [
          fulfillment_status: fulfillment,
          fulfillment_updated_at: now
        ]
      )
    end)
  end

  defp resolve_status("shipped"),   do: "in_transit"
  defp resolve_status("delivered"), do: "completed"
  defp resolve_status("cancelled"), do: "voided"
  defp resolve_status(_),           do: "pending"

  # VALIDATION: SMELL END
end
```
