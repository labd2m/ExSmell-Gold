# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `key_to_atom/1` helper used inside `atomize_keys/1`
- **Affected function(s):** `key_to_atom/1`, `atomize_keys/1`
- **Short explanation:** The `atomize_keys/1` function recursively converts all map keys from the external API response into atoms using `String.to_atom/1`. Because the response structure and its keys are determined by the external inventory service, any new or unexpected key will create a permanent atom, with no upper bound on how many can accumulate.

---

```elixir
defmodule Inventory.ProductCatalogSync do
  @moduledoc """
  Synchronises the local product catalogue with the upstream inventory service.
  Fetches product records in pages and upserts them into the local store.
  """

  require Logger

  alias Inventory.{InventoryClient, ProductRepo, SyncAudit}

  @page_size 100
  @sync_fields ~w(sku name description price stock_quantity unit weight category_id)

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    warehouse_id = Keyword.fetch!(opts, :warehouse_id)
    since = Keyword.get(opts, :since)

    Logger.info("Starting catalogue sync", warehouse_id: warehouse_id)

    with {:ok, audit} <- SyncAudit.start(warehouse_id),
         {:ok, stats} <- sync_all_pages(warehouse_id, since),
         {:ok, _} <- SyncAudit.complete(audit.id, stats) do
      Logger.info("Catalogue sync finished", stats: inspect(stats))
      {:ok, stats}
    else
      {:error, reason} = err ->
        Logger.error("Catalogue sync failed", reason: inspect(reason))
        err
    end
  end

  defp sync_all_pages(warehouse_id, since) do
    do_sync_page(warehouse_id, since, 1, %{upserted: 0, skipped: 0, errors: 0})
  end

  defp do_sync_page(warehouse_id, since, page, acc) do
    case InventoryClient.list_products(warehouse_id,
           page: page,
           per_page: @page_size,
           updated_since: since
         ) do
      {:ok, %{"products" => [], "total_pages" => _}} ->
        {:ok, acc}

      {:ok, %{"products" => products, "total_pages" => total}} ->
        new_acc = process_products(products, acc)

        if page >= total do
          {:ok, new_acc}
        else
          do_sync_page(warehouse_id, since, page + 1, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_products(products, acc) do
    Enum.reduce(products, acc, fn raw, stats ->
      # VALIDATION: SMELL START - Dynamic atom creation
      # VALIDATION: This is a smell because `atomize_keys/1` calls
      # `String.to_atom/1` on every key in the raw product map returned by the
      # external inventory API. The API may add or rename fields at any time,
      # and nested maps are also fully atomized. Every new or unexpected key
      # creates a permanent atom, making growth of the atom table entirely
      # dependent on the third-party service's behaviour.
      product = atomize_keys(raw)
      # VALIDATION: SMELL END

      case upsert_product(product) do
        {:ok, _} -> Map.update!(stats, :upserted, &(&1 + 1))
        {:skip, _} -> Map.update!(stats, :skipped, &(&1 + 1))
        {:error, _} -> Map.update!(stats, :errors, &(&1 + 1))
      end
    end)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {key_to_atom(k), atomize_keys(v)} end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp key_to_atom(key) when is_binary(key), do: String.to_atom(key)
  defp key_to_atom(key), do: key

  defp upsert_product(product) do
    attrs = Map.take(product, Enum.map(@sync_fields, &String.to_atom/1))

    case ProductRepo.get_by_sku(product.sku) do
      nil ->
        ProductRepo.insert(attrs)

      existing ->
        if product_changed?(existing, attrs) do
          ProductRepo.update(existing, attrs)
        else
          {:skip, existing}
        end
    end
  end

  defp product_changed?(existing, new_attrs) do
    Enum.any?(new_attrs, fn {k, v} -> Map.get(existing, k) != v end)
  end
end
```
