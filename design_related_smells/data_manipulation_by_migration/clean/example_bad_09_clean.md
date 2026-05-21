```elixir
defmodule Catalog.Repo.Migrations.AddSlugToProducts do
  use Ecto.Migration

  import Ecto.Query
  alias Catalog.Repo

  def change do
    alter table("products") do
      add :slug, :string, null: true
    end

    create unique_index("products", [:slug])

    flush()

    populate_slugs()
  end

  defp populate_slugs do
    from(p in "products",
      where: is_nil(p.slug),
      select: %{id: p.id, name: p.name, sku: p.sku}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, name: name, sku: sku} ->
      slug = generate_slug(name, sku)

      from(p in "products", where: p.id == ^id)
      |> Repo.update_all(set: [slug: slug])
    end)
  end

  defp generate_slug(name, sku) when is_binary(name) and is_binary(sku) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    suffix =
      sku
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    "#{base}-#{suffix}"
  end

  defp generate_slug(name, _sku) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

  defp generate_slug(_, _), do: "product-#{System.unique_integer([:positive])}"
end
```
