# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `assign_sort_orders/0`
- **Short explanation:** The migration adds a `sort_order` column to `menu_items` and then groups existing rows by `menu_id`, assigns sequential integer positions within each group, and writes those positions back to the table. Generating and persisting computed ordering values for existing rows is a data manipulation task that should be placed in a dedicated Mix task.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after the structural alteration the
    # migration fetches all menu_item rows, groups them by menu_id, assigns
    # sequential sort_order values per group, and writes those values back to
    # the database. Deriving and persisting computed row-level data belongs in
    # a separate Mix task, not in an Ecto.Migration module.
    assign_sort_orders()
    # VALIDATION: SMELL END
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
