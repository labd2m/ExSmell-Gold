```elixir
defmodule Restaurant.Repo.Migrations.AddSortOrderToMenuItems do
  use Ecto.Migration

  import Ecto.Query
  alias Restaurant.Repo

  def change do
    alter table("menu_items") do
      add :sort_order,        :integer, null: true
      add :sort_order_locked, :boolean, default: false, null: false
    end

    create index("menu_items", [:menu_id, :sort_order])

    flush()

    assign_sort_orders()
  end

  defp assign_sort_orders do
    rows =
      from(m in "menu_items",
        order_by: [asc: m.menu_id, asc: m.inserted_at],
        select: %{id: m.id, menu_id: m.menu_id}
      )
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.menu_id)
    |> Enum.each(fn {_menu_id, items} ->
      items
      |> Enum.with_index(1)
      |> Enum.each(fn {%{id: id}, position} ->
        from(m in "menu_items", where: m.id == ^id)
        |> Repo.update_all(set: [sort_order: position])
      end)
    end)
  end
end
```
