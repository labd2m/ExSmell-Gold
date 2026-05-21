```elixir
defmodule Commerce.Repo.Migrations.AddFulfillmentStatusToOrders do
  use Ecto.Migration


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

end
```
