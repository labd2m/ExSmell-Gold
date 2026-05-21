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

    archive_old_orders()
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
