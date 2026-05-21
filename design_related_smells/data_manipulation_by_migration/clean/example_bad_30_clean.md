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

    migrate_category_references()
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
