```elixir
defmodule Mix.Tasks.Store.SeedCatalog do
  @shortdoc "Seeds the catalog database with initial categories and products"

  @moduledoc """
  Populates the product catalog with demo fixtures suitable for local
  development and staging environments. This task is idempotent: running
  it multiple times will upsert without creating duplicates.

  ## Usage

      mix store.seed_catalog
      mix store.seed_catalog --limit 10
  """

  use Mix.Task

  alias Store.{Repo, Catalog}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [limit: :integer])
    limit = Keyword.get(opts, :limit, :all)

    Mix.shell().info("Seeding catalog (limit: #{limit})...")

    with {:ok, categories} <- seed_categories(),
         :ok <- seed_products(categories, limit) do
      Mix.shell().info("Catalog seeding complete.")
    else
      {:error, reason} ->
        Mix.shell().error("Seeding failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp seed_categories do
    fixtures = category_fixtures()

    results =
      Enum.map(fixtures, fn attrs ->
        case Catalog.upsert_category(attrs) do
          {:ok, cat} ->
            Mix.shell().info("  category: #{cat.label}")
            {:ok, cat}

          {:error, changeset} ->
            Mix.shell().error("  failed category #{attrs.slug}: #{format_errors(changeset)}")
            {:error, changeset}
        end
      end)

    case Enum.filter(results, &match?({:error, _}, &1)) do
      [] -> {:ok, Enum.map(results, fn {:ok, c} -> c end)}
      errors -> {:error, errors}
    end
  end

  defp seed_products(categories, limit) do
    by_slug = Map.new(categories, &{&1.slug, &1.id})

    fixtures =
      product_fixtures()
      |> apply_limit(limit)

    Enum.each(fixtures, fn attrs ->
      full = Map.put(attrs, :category_id, Map.get(by_slug, attrs.category_slug))

      case Catalog.upsert_product(full) do
        {:ok, p} -> Mix.shell().info("  product: #{p.name}")
        {:error, cs} -> Mix.shell().error("  failed product #{attrs.sku}: #{format_errors(cs)}")
      end
    end)

    :ok
  end

  defp apply_limit(list, :all), do: list
  defp apply_limit(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)

  defp format_errors(changeset) do
    changeset.errors |> Enum.map(fn {k, {msg, _}} -> "#{k}: #{msg}" end) |> Enum.join(", ")
  end

  defp category_fixtures do
    [
      %{slug: "electronics", label: "Electronics"},
      %{slug: "clothing", label: "Clothing"},
      %{slug: "home-garden", label: "Home & Garden"}
    ]
  end

  defp product_fixtures do
    [
      %{sku: "ELEC-001", name: "Wireless Keyboard", price_cents: 4_999, category_slug: "electronics"},
      %{sku: "ELEC-002", name: "USB-C Hub 7-Port", price_cents: 2_499, category_slug: "electronics"},
      %{sku: "CLO-001", name: "Merino Wool Sweater", price_cents: 8_900, category_slug: "clothing"},
      %{sku: "CLO-002", name: "Waterproof Rain Jacket", price_cents: 12_000, category_slug: "clothing"},
      %{sku: "HG-001", name: "Cast Iron Skillet 10\"", price_cents: 3_500, category_slug: "home-garden"}
    ]
  end
end
```
