---
smell_name: Complex branching
smell_location: Inventory.SupplierSync.handle_stock_response/2
affected_functions:
  - handle_stock_response/2
explanation: >
  `handle_stock_response/2` handles 16 distinct response shapes from a single
  supplier stock-feed API call in one `case` expression. The function weaves
  together HTTP status checks, business-level error codes (e.g. sync_in_progress,
  invalid_supplier_code), logging, and partial-feed cursor management in the
  same block. The supplier context passed as the second argument compounds the
  problem by requiring interpolated log messages in each branch, making the
  function even longer. Any new supplier-specific error code forces a change
  here, risking regressions for all existing branches.
---

```elixir
defmodule Inventory.SupplierSync do
  @moduledoc """
  Synchronises stock levels from supplier EDI/API feeds into the local
  inventory management system. Handles both incremental and full sync modes.
  """

  require Logger

  alias Inventory.{Product, StockLevel, Supplier, SyncLog}
  alias Inventory.Repo

  @sync_timeout 30_000
  @batch_size 100

  def run_sync(supplier_id, mode \\ :incremental) do
    with {:ok, supplier} <- Supplier.fetch(supplier_id),
         :ok <- ensure_supplier_active(supplier),
         {:ok, stock_data} <- fetch_supplier_stock(supplier, mode) do
      apply_stock_updates(supplier, stock_data)
    end
  end

  def schedule_full_sync(supplier_id) do
    with {:ok, supplier} <- Supplier.fetch(supplier_id) do
      :ok = SyncLog.mark_full_sync_requested(supplier_id)
      Logger.info("Full sync scheduled for supplier #{supplier.name}")
      {:ok, :scheduled}
    end
  end

  defp ensure_supplier_active(%Supplier{status: "active"}), do: :ok

  defp ensure_supplier_active(%Supplier{status: status}),
    do: {:error, {:supplier_not_active, status}}

  defp fetch_supplier_stock(%Supplier{} = supplier, mode) do
    params = %{
      supplier_code: supplier.external_code,
      mode: Atom.to_string(mode),
      since: last_sync_timestamp(supplier),
      format: "json"
    }

    SupplierAPI.get_stock_feed(supplier.api_endpoint, params, timeout: @sync_timeout)
    |> handle_stock_response(supplier)
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because a single function handles 16 different
  # response shapes from one supplier API endpoint. Logging messages embed the
  # supplier struct, meaning every branch is tightly coupled to calling context.
  # The mix of transport-level concerns (HTTP statuses, headers), domain codes
  # (sync_in_progress, invalid_date_range), and partial-result signalling
  # ({:partial, ...}) makes cyclomatic complexity extremely high and testing
  # each path in isolation impractical.
  defp handle_stock_response(response, supplier) do
    case response do
      {:ok, %{status: 200, body: %{"items" => items, "total_count" => count}}} ->
        Logger.info("Received #{count} stock items from supplier #{supplier.name}")
        {:ok, %{items: items, count: count, full: true}}

      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, %{items: items, count: length(items), full: false}}

      {:ok, %{status: 206, body: %{"items" => items, "next_cursor" => cursor}}} ->
        Logger.info("Partial stock feed from #{supplier.name}, cursor=#{cursor}")
        {:partial, %{items: items, cursor: cursor}}

      {:ok, %{status: 204}} ->
        Logger.info("No stock changes from supplier #{supplier.name} since last sync")
        {:ok, %{items: [], count: 0, full: false}}

      {:ok, %{status: 400, body: %{"error" => "invalid_supplier_code"}}} ->
        Logger.error("Supplier code not recognised: #{supplier.external_code}")
        {:error, :invalid_supplier_code}

      {:ok, %{status: 400, body: %{"error" => "invalid_date_range", "message" => msg}}} ->
        Logger.warning("Invalid date range in stock request: #{msg}")
        {:error, {:invalid_date_range, msg}}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        {:error, {:bad_request, msg}}

      {:ok, %{status: 401}} ->
        Logger.error("Supplier API authentication failed for #{supplier.name}")
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        Logger.error("Access denied by supplier #{supplier.name}")
        {:error, :access_denied}

      {:ok, %{status: 404}} ->
        {:error, :supplier_feed_not_found}

      {:ok, %{status: 409, body: %{"error" => "sync_in_progress"}}} ->
        Logger.warning("Supplier #{supplier.name} already has a sync in progress")
        {:error, :sync_in_progress}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = parse_retry_after(headers)
        Logger.warning("Supplier API rate limited, retry in #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 500}} ->
        Logger.error("Supplier #{supplier.name} API internal error")
        {:error, :supplier_api_error}

      {:ok, %{status: 503}} ->
        Logger.warning("Supplier API unavailable for #{supplier.name}")
        {:error, :service_unavailable}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected response #{status} from supplier #{supplier.name}")
        {:error, {:unexpected_status, status}}

      {:error, :timeout} ->
        Logger.error("Supplier API timed out for #{supplier.name}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Supplier API error for #{supplier.name}: #{inspect(reason)}")
        {:error, {:api_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  defp apply_stock_updates(supplier, %{items: items}) do
    items
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      Repo.transaction(fn ->
        Enum.each(batch, fn item ->
          case Product.find_by_sku(item["sku"]) do
            nil ->
              Logger.warning("SKU #{item["sku"]} not found in local catalogue")

            product ->
              StockLevel.upsert!(%{
                product_id: product.id,
                supplier_id: supplier.id,
                quantity: item["quantity"],
                warehouse: item["warehouse"],
                updated_at: DateTime.utc_now()
              })
          end
        end)
      end)
    end)

    SyncLog.record_sync(supplier.id, length(items))
    {:ok, length(items)}
  end

  defp last_sync_timestamp(supplier) do
    case SyncLog.last_sync(supplier.id) do
      nil -> nil
      log -> DateTime.to_iso8601(log.completed_at)
    end
  end

  defp parse_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, v} -> String.to_integer(v)
      nil -> 120
    end
  end
end
```
