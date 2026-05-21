```elixir
defmodule Storefront.Repo.Migrations.AddSlugToProducts do
  use Ecto.Migration

  import Ecto.Query
  alias Storefront.Repo

  def change do
    alter table("products") do
      add :slug, :string, null: true
    end

    create unique_index("products", [:slug])

    flush()

    backfill_slugs()

    alter table("products") do
      modify :slug, :string, null: false
    end
  end

  defp backfill_slugs do
    products =
      from(p in "products",
        select: %{id: p.id, name: p.name}
      )
      |> Repo.all()

    Enum.each(products, fn %{id: id, name: name} ->
      slug = slugify(name)

      from(p in "products", where: p.id == ^id)
      |> Repo.update_all(set: [slug: slug])
    end)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
```
