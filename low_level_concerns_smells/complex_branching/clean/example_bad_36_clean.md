# Example 36

```elixir
defmodule Inventory.StockAdjustment do
  @moduledoc """
  Applies stock adjustments, reservations, and write-offs via the WarehouseOS API.
  Used by order fulfilment, returns processing, and cycle-count reconciliation.
  """

  require Logger

  alias Inventory.Repo
  alias Inventory.Schema.{StockLedger, Product, Warehouse}
  alias Inventory.WarehouseOS.Client
  alias Inventory.Alerts

  @adjustment_reasons ~w(sale return damage cycle_count write_off reservation)
  @quarantine_threshold 3

  def adjust(product_id, warehouse_id, delta, reason, opts \\ [])
      when reason in @adjustment_reasons do
    reference = Keyword.get(opts, :reference, generate_ref())

    with {:ok, product} <- fetch_product(product_id),
         {:ok, warehouse} <- fetch_warehouse(warehouse_id),
         :ok <- validate_delta(delta, reason) do
      apply_adjustment(
        product,
        Client.post("/adjustments", %{
          sku: product.sku,
          warehouse_code: warehouse.code,
          delta: delta,
          reason: reason,
          reference: reference
        })
      )
    end
  end

  defp fetch_product(id) do
    case Repo.get(Product, id) do
      nil -> {:error, :product_not_found}
      p -> {:ok, p}
    end
  end

  defp fetch_warehouse(id) do
    case Repo.get(Warehouse, id) do
      nil -> {:error, :warehouse_not_found}
      w -> {:ok, w}
    end
  end

  defp validate_delta(delta, "sale") when delta >= 0, do: {:error, :sale_delta_must_be_negative}
  defp validate_delta(delta, "return") when delta <= 0, do: {:error, :return_delta_must_be_positive}
  defp validate_delta(_, _), do: :ok

  defp generate_ref, do: "ADJ-#{System.unique_integer([:positive])}"

  defp apply_adjustment(product, warehouse_response) do
    case warehouse_response do
      {:ok, %{status: 200, body: %{"adjustment_id" => adj_id, "new_quantity" => qty, "status" => "accepted"}}} ->
        Logger.info("Adjustment #{adj_id} accepted for SKU #{product.sku}, new qty: #{qty}")

        Repo.insert(%StockLedger{
          product_id: product.id,
          adjustment_id: adj_id,
          resulting_quantity: qty,
          status: :accepted
        })

        {:ok, %{adjustment_id: adj_id, quantity: qty}}

      {:ok, %{status: 206, body: %{"adjustment_id" => adj_id, "filled" => filled, "requested" => req}}} ->
        Logger.warning("Partial adjustment #{adj_id} for SKU #{product.sku}: #{filled}/#{req} filled")

        Repo.insert(%StockLedger{
          product_id: product.id,
          adjustment_id: adj_id,
          resulting_quantity: filled,
          status: :partial
        })

        Alerts.notify_partial_fill(product, filled, req)
        {:ok, %{adjustment_id: adj_id, filled: filled, requested: req, status: :partial}}

      {:ok, %{status: 200, body: %{"adjustment_id" => adj_id, "status" => "reserved", "release_at" => release}}} ->
        Logger.info("Stock reserved for SKU #{product.sku}, releases at #{release}")
        {:ok, %{adjustment_id: adj_id, status: :reserved, release_at: release}}

      {:ok, %{status: 422, body: %{"error" => "out_of_stock"}}} ->
        Logger.warning("Out of stock for SKU #{product.sku}")
        Alerts.notify_stockout(product)
        {:error, :out_of_stock}

      {:ok, %{status: 422, body: %{"error" => "below_safety_stock", "safety_level" => level}}} ->
        Logger.warning("Adjustment would breach safety stock (#{level}) for SKU #{product.sku}")
        {:error, {:below_safety_stock, level}}

      {:ok, %{status: 409, body: %{"error" => "quarantine_flag", "incident_id" => iid}}} ->
        Logger.error("SKU #{product.sku} flagged for quarantine, incident #{iid}")
        Alerts.notify_quarantine(product, iid)
        {:error, {:quarantine_flag, iid}}

      {:ok, %{status: 404, body: %{"error" => "sku_not_found_in_warehouse"}}} ->
        Logger.warning("SKU #{product.sku} not registered in target warehouse")
        {:error, :sku_not_in_warehouse}

      {:ok, %{status: 409, body: %{"error" => "concurrent_adjustment"}}} ->
        Logger.warning("Concurrent adjustment conflict for SKU #{product.sku}")
        {:error, :concurrent_adjustment}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by WarehouseOS for SKU #{product.sku}")
        {:error, :rate_limited}

      {:ok, %{status: 500, body: body}} ->
        Logger.error("WarehouseOS internal error for SKU #{product.sku}: #{inspect(body)}")
        {:error, :warehouse_internal_error}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("WarehouseOS unavailable for SKU #{product.sku}")
        {:error, :warehouse_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected WarehouseOS response #{status} for SKU #{product.sku}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("WarehouseOS timeout for SKU #{product.sku}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("WarehouseOS error for SKU #{product.sku}: #{inspect(reason)}")
        {:error, {:warehouse_error, reason}}
    end
  end

  def ledger_history(product_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    StockLedger
    |> StockLedger.for_product(product_id)
    |> StockLedger.order_by_desc_inserted()
    |> StockLedger.limit(limit)
    |> Repo.all()
  end
end
```
