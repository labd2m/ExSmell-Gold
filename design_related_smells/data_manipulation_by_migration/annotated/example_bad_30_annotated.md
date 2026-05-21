# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `migrate_category_references/0`
- **Short explanation:** The migration adds a `category_id` foreign-key column to `articles` and then executes cross-table queries to look up category IDs by name and update each article row accordingly. Resolving and writing foreign-key references for existing rows is a data manipulation responsibility that should not be bundled with schema structure changes.

---

```elixir
defmodule CMS.Repo.Migrations.AddCategoryIdToArticles do
  use Ecto.Migration

  import Ecto.Query
  alias CMS.Repo

  def change do
    alter table("articles") do
      add :category_id, references("categories", on_delete: :nilify_all), null: true
    end

    create index("articles", [:category_id])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after adding the foreign-key column,
    # the migration queries the categories table to resolve IDs and then
    # updates every article row to populate the new category_id based on the
    # existing free-text category_name field. This cross-table data migration
    # is a data manipulation concern mixed into a structural schema change,
    # violating the single responsibility of an Ecto.Migration module.
    migrate_category_references()
    # VALIDATION: SMELL END
  end

  defp migrate_category_references do
    categories =
      from(c in "categories", select: %{id: c.id, name: c.name})
      |> Repo.all()

    category_lookup = Map.new(categories, fn %{id: id, name: name} -> {name, id} end)

    articles =
      from(a in "articles",
        where: not is_nil(a.category_name),
        select: %{id: a.id, category_name: a.category_name}
      )
      |> Repo.all()

    Enum.each(articles, fn %{id: id, category_name: name} ->
      case Map.get(category_lookup, name) do
        nil ->
          :ok

        category_id ->
          from(a in "articles", where: a.id == ^id)
          |> Repo.update_all(set: [category_id: category_id])
      end
    end)
  end
end
```
