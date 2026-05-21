# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_slugs/0`, `slugify/1`
- **Short explanation:** The migration both adds a structural column (`slug`) to the `products` table and then immediately queries and updates existing rows to populate that column with computed values — mixing schema evolution with data transformation in a single migration module.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after performing the structural change
    # (adding the :slug column), the migration immediately queries all existing
    # product rows and updates them with computed slug values. Data backfilling
    # should be done in a separate Mix task, not inside Ecto.Migration.
    backfill_slugs()
    # VALIDATION: SMELL END

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
