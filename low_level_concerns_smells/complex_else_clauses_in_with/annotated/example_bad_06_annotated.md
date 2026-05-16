# Annotated Bad Example 6

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `reserve_stock/3`, inside the `with` block's `else` clause
- **Affected function(s):** `reserve_stock/3`
- **Short explanation:** Five sequential stock-reservation steps—each returning a distinct failure value—are all caught in one `else` block. Errors from product lookup, warehouse resolution, stock level checks, reservation creation, and ERP sync are indistinguishable without tracing each helper function individually.

```elixir
defmodule Inventory.StockReservation do
  alias Inventory.{Repo, Product, WarehouseStock, Reservation, ERPClient}

  require Logger

  @reservation_ttl_minutes 60

  def reserve_stock(product_sku, quantity, order_ref) do
    with {:ok, product} <- fetch_active_product(product_sku),
         {:ok, stock} <- find_available_stock(product, quantity),
         :ok <- check_reservation_conflicts(stock, quantity),
         {:ok, reservation} <- create_reservation(stock, product, quantity, order_ref),
         {:ok, _} <- ERPClient.sync_reservation(reservation) do
      Logger.info(
        "Reserved #{quantity}x #{product_sku} for order #{order_ref} " <>
          "(reservation=#{reservation.id})"
      )

      {:ok, %{
        reservation_id: reservation.id,
        expires_at: reservation.expires_at,
        warehouse: stock.warehouse_code
      }}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because the `else` block conflates errors from five
      # different pipeline steps. `:not_found` and `:discontinued` come from product lookup;
      # `:no_stock_available` comes from stock search; `:insufficient_quantity` and
      # `:conflict` come from the conflict check; and `:erp_sync_failed` comes from the
      # ERP call. Readers must trace each helper to understand which step fails
      # under which condition.
      {:error, :not_found} ->
        Logger.warning("Product SKU #{product_sku} not found during reservation")
        {:error, :product_not_found}

      {:error, :discontinued} ->
        Logger.warning("Attempted to reserve discontinued SKU #{product_sku}")
        {:error, :product_discontinued}

      {:error, :no_stock_available} ->
        Logger.warning("No stock available for SKU #{product_sku} qty=#{quantity}")
        {:error, :out_of_stock}

      {:error, :insufficient_quantity} ->
        Logger.warning("Insufficient stock for SKU #{product_sku} qty=#{quantity}")
        {:error, :insufficient_stock}

      {:error, :conflict} ->
        Logger.warning("Reservation conflict for SKU #{product_sku} order=#{order_ref}")
        {:error, :reservation_conflict}

      {:error, :erp_sync_failed} ->
        Logger.error("ERP sync failed for reservation of SKU #{product_sku}")
        {:error, :erp_unavailable}

      {:error, reason} ->
        Logger.error("Unexpected reservation error for #{product_sku}: #{inspect(reason)}")
        {:error, :internal_error}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_active_product(sku) do
    case Repo.get_by(Product, sku: sku) do
      nil -> {:error, :not_found}
      %Product{status: :discontinued} -> {:error, :discontinued}
      product -> {:ok, product}
    end
  end

  defp find_available_stock(%Product{id: product_id}, quantity) do
    case Repo.get_by(WarehouseStock, product_id: product_id, active: true) do
      nil ->
        {:error, :no_stock_available}

      %WarehouseStock{available_qty: avail} when avail < quantity ->
        {:error, :insufficient_quantity}

      stock ->
        {:ok, stock}
    end
  end

  defp check_reservation_conflicts(stock, quantity) do
    pending_reservations =
      Repo.aggregate(
        from(r in Reservation,
          where: r.stock_id == ^stock.id and r.status == :pending
        ),
        :sum,
        :quantity
      ) || 0

    if stock.available_qty - pending_reservations >= quantity do
      :ok
    else
      {:error, :conflict}
    end
  end

  defp create_reservation(stock, product, quantity, order_ref) do
    expires_at = DateTime.add(DateTime.utc_now(), @reservation_ttl_minutes * 60)

    Repo.insert(%Reservation{
      stock_id: stock.id,
      product_id: product.id,
      quantity: quantity,
      order_ref: order_ref,
      status: :pending,
      expires_at: expires_at
    })
  end
end
```
