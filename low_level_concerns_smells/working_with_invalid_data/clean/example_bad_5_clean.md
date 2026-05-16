```elixir
defmodule MyApp.Inventory.InventoryManager do
  @moduledoc """
  Manages warehouse inventory levels, stock reservations, and replenishment
  triggers. Integrates with the ERP adapter for real-time syncing.
  """

  require Logger

  alias MyApp.Inventory.{StockRecord, ReservationLedger, ReplenishmentQueue}
  alias MyApp.Warehouse.LocationRegistry

  @low_stock_threshold 10
  @critical_stock_threshold 3
  @max_adjustment_batch 500

  @type adjustment_reason ::
          :sale | :return | :damage | :correction | :transfer_in | :transfer_out

  @spec adjust_stock(String.t(), String.t(), term(), adjustment_reason()) ::
          {:ok, StockRecord.t()} | {:error, atom()}
  def adjust_stock(sku, warehouse_id, delta, reason) do
    with {:ok, record} <- StockRecord.fetch(sku, warehouse_id),
         :ok <- check_adjustment_limits(delta),
         :ok <- validate_reason(reason) do
      current_qty = record.quantity
      
      new_qty = current_qty + delta
    
      if new_qty < 0 do
        {:error, :insufficient_stock}
      else
        updated_record = %{record | quantity: new_qty, last_adjusted_at: DateTime.utc_now()}

        with {:ok, saved} <- StockRecord.save(updated_record),
             :ok <- maybe_trigger_replenishment(saved, reason),
             :ok <- log_adjustment(sku, warehouse_id, delta, reason, current_qty, new_qty) do
          {:ok, saved}
        end
      end
    end
  end

  @spec reserve_stock(String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def reserve_stock(sku, warehouse_id, quantity, order_id) do
    with {:ok, record} <- StockRecord.fetch(sku, warehouse_id),
         :ok <- check_available(record, quantity) do
      ReservationLedger.create(%{
        sku: sku,
        warehouse_id: warehouse_id,
        quantity: quantity,
        order_id: order_id,
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
      })
    end
  end

  @spec release_reservation(String.t()) :: :ok | {:error, atom()}
  def release_reservation(reservation_id) do
    with {:ok, reservation} <- ReservationLedger.fetch(reservation_id) do
      ReservationLedger.cancel(reservation_id)
      adjust_stock(reservation.sku, reservation.warehouse_id, reservation.quantity, :return)
      :ok
    end
  end

  @spec stock_level(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def stock_level(sku, warehouse_id) do
    with {:ok, record} <- StockRecord.fetch(sku, warehouse_id),
         {:ok, reserved} <- ReservationLedger.total_reserved(sku, warehouse_id) do
      {:ok,
       %{
         sku: sku,
         warehouse_id: warehouse_id,
         on_hand: record.quantity,
         reserved: reserved,
         available: record.quantity - reserved,
         status: classify_stock_level(record.quantity)
       }}
    end
  end

  # Private helpers

  defp check_available(record, quantity) do
    if record.quantity >= quantity, do: :ok, else: {:error, :insufficient_stock}
  end

  defp check_adjustment_limits(delta) when abs(delta) > @max_adjustment_batch,
    do: {:error, :adjustment_exceeds_limit}

  defp check_adjustment_limits(_), do: :ok

  defp validate_reason(reason) when reason in [:sale, :return, :damage, :correction,
                                                :transfer_in, :transfer_out], do: :ok
  defp validate_reason(_), do: {:error, :invalid_reason}

  defp classify_stock_level(qty) when qty <= @critical_stock_threshold, do: :critical
  defp classify_stock_level(qty) when qty <= @low_stock_threshold, do: :low
  defp classify_stock_level(_qty), do: :normal

  defp maybe_trigger_replenishment(record, :sale) do
    if classify_stock_level(record.quantity) in [:critical, :low] do
      ReplenishmentQueue.enqueue(record.sku, record.warehouse_id)
    else
      :ok
    end
  end

  defp maybe_trigger_replenishment(_, _), do: :ok

  defp log_adjustment(sku, warehouse_id, delta, reason, old_qty, new_qty) do
    Logger.info(
      "Stock adjusted: sku=#{sku} warehouse=#{warehouse_id} " <>
        "delta=#{delta} reason=#{reason} #{old_qty}->#{new_qty}"
    )
    :ok
  end
end
```
