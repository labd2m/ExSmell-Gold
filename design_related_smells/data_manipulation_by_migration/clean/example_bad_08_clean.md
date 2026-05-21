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

    backfill_order_status()
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
