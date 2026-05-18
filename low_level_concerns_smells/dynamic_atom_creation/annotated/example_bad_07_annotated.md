# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `InventorySync.map_supplier_attributes/1`, line where `String.to_atom/1` converts supplier attribute keys |
| **Affected function(s)** | `InventorySync.map_supplier_attributes/1` |
| **Short explanation** | Attribute keys from a supplier's JSON feed are converted to atoms to build a product attribute map. The supplier controls the key names, meaning any schema change on their side—or a compromised feed—will silently create new permanent atoms on every sync cycle. |

```elixir
defmodule MyApp.Inventory.InventorySync do
  @moduledoc """
  Synchronises product inventory data with upstream supplier feeds.
  Runs on a scheduled basis via Oban and reconciles local stock levels,
  pricing, and product attributes against the canonical supplier source.
  """

  use Oban.Worker, queue: :inventory_sync, max_attempts: 3

  require Logger

  alias MyApp.Inventory.{Product, ProductRepo, StockLevel}
  alias MyApp.Suppliers.FeedClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"supplier_id" => supplier_id}}) do
    Logger.info("Starting inventory sync", supplier_id: supplier_id)

    with {:ok, feed} <- FeedClient.fetch(supplier_id),
         {:ok, products} <- parse_feed(feed),
         {:ok, results} <- sync_products(products, supplier_id) do
      Logger.info("Inventory sync complete", supplier_id: supplier_id, synced: length(results))
      :ok
    else
      {:error, reason} = err ->
        Logger.error("Inventory sync failed", supplier_id: supplier_id, reason: inspect(reason))
        err
    end
  end

  defp parse_feed(%{"products" => products}) when is_list(products) do
    parsed =
      Enum.reduce_while(products, [], fn raw, acc ->
        case parse_product(raw) do
          {:ok, product} -> {:cont, [product | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case parsed do
      {:error, _} = err -> err
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_feed(_), do: {:error, :invalid_feed_format}

  defp parse_product(%{"sku" => sku, "stock" => stock, "price" => price} = raw) do
    with {:ok, attrs} <- map_supplier_attributes(Map.get(raw, "attributes", %{})) do
      {:ok, %{sku: sku, stock: stock, price_cents: round(price * 100), attributes: attrs}}
    end
  end

  defp parse_product(_), do: {:error, :missing_required_fields}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to every key
  # in the `"attributes"` map that comes from a third-party supplier's JSON feed.
  # Suppliers routinely add, rename, or restructure attribute keys without notice.
  # Each new or renamed key will create a new permanent atom on every sync run.
  # Over time—or across many suppliers—this silently fills BEAM's atom table.
  # String keys or a validated lookup map should be used instead.
  defp map_supplier_attributes(raw_attrs) when is_map(raw_attrs) do
    attrs =
      Map.new(raw_attrs, fn {key, value} ->
        {String.to_atom(key), value}
      end)

    {:ok, attrs}
  end
  # VALIDATION: SMELL END

  defp map_supplier_attributes(_), do: {:ok, %{}}

  defp sync_products(products, supplier_id) do
    results =
      Enum.map(products, fn product ->
        case ProductRepo.find_by_sku(product.sku) do
          {:ok, existing} -> update_product(existing, product, supplier_id)
          {:error, :not_found} -> create_product(product, supplier_id)
        end
      end)

    {:ok, results}
  end

  defp create_product(product, supplier_id) do
    ProductRepo.insert(%Product{
      sku: product.sku,
      supplier_id: supplier_id,
      attributes: product.attributes,
      price_cents: product.price_cents,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp update_product(existing, product, _supplier_id) do
    ProductRepo.update(existing, %{
      attributes: product.attributes,
      price_cents: product.price_cents,
      updated_at: DateTime.utc_now()
    })

    StockLevel.reconcile(existing.id, product.stock)
  end
end
```
