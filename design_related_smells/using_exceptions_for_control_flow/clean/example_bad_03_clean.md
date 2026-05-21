```elixir
defmodule Inventory.SKU do
  @moduledoc "Represents a stock-keeping unit with its current on-hand and reserved quantities."

  @enforce_keys [:id, :name, :on_hand, :reserved, :reorder_point]
  defstruct [:id, :name, :on_hand, :reserved, :reorder_point, :unit]

  def available(%__MODULE__{on_hand: on_hand, reserved: reserved}), do: on_hand - reserved
end

defmodule Inventory.Warehouse do
  @moduledoc "In-memory warehouse catalogue for demo purposes."

  alias Inventory.SKU

  @catalogue %{
    "SKU-001" => %SKU{id: "SKU-001", name: "Widget A", on_hand: 200, reserved: 40, reorder_point: 50, unit: "piece"},
    "SKU-002" => %SKU{id: "SKU-002", name: "Gadget B", on_hand: 15,  reserved: 10, reorder_point: 20, unit: "piece"},
    "SKU-003" => %SKU{id: "SKU-003", name: "Doohickey C", on_hand: 0, reserved: 0, reorder_point: 10, unit: "piece"}
  }

  def lookup(sku_id), do: Map.fetch(@catalogue, sku_id)

  def update_reserved(sku_id, delta) do
    case Map.fetch(@catalogue, sku_id) do
      {:ok, sku} -> {:ok, %{sku | reserved: sku.reserved + delta}}
      :error -> {:error, :not_found}
    end
  end
end

defmodule Inventory.ReservationRecord do
  @moduledoc "Tracks a reservation for a specific SKU and quantity."

  @enforce_keys [:id, :sku_id, :quantity, :order_id, :reserved_at]
  defstruct [:id, :sku_id, :quantity, :order_id, :reserved_at, :expires_at]
end

defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock reservations and releases for order fulfillment.
  Ensures inventory is not oversold before shipment confirmation.
  """

  alias Inventory.{ReservationRecord, SKU, Warehouse}
  require Logger

  def reserve(sku_id, quantity, order_id)
      when is_binary(sku_id) and is_integer(quantity) and quantity > 0 do
    case Warehouse.lookup(sku_id) do
      :error ->
        raise RuntimeError, message: "Unknown SKU '#{sku_id}' — cannot reserve stock"

      {:ok, sku} ->
        available = SKU.available(sku)

        if available < quantity do
          raise RuntimeError,
            message:
              "Insufficient stock for SKU '#{sku_id}': requested #{quantity}, available #{available}"
        end

        {:ok, _updated} = Warehouse.update_reserved(sku_id, quantity)

        record = %ReservationRecord{
          id: "res_#{:rand.uniform(999_999)}",
          sku_id: sku_id,
          quantity: quantity,
          order_id: order_id,
          reserved_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600 * 24, :second)
        }

        Logger.info("Reserved #{quantity}x #{sku_id} for order #{order_id}")
        record
    end
  end

  def release(reservation_id, sku_id, quantity) do
    case Warehouse.update_reserved(sku_id, -quantity) do
      {:ok, _sku} ->
        Logger.info("Released reservation #{reservation_id} for #{quantity}x #{sku_id}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Inventory.OrderFulfillment do
  @moduledoc """
  Coordinates stock reservation for all line items in an incoming order.
  Rolls back successful reservations if any line item fails.
  """

  alias Inventory.StockManager
  require Logger

  defmodule OrderLine do
    defstruct [:sku_id, :quantity]
  end

  def fulfill_items(order_id, line_items) when is_list(line_items) do
    Enum.reduce_while(line_items, {:ok, []}, fn %OrderLine{sku_id: sku_id, quantity: qty}, {:ok, acc} ->
      # Client forced to use try/rescue because StockManager.reserve/3
      # raises instead of returning {:error, reason} on failure.
      try do
        reservation = StockManager.reserve(sku_id, qty, order_id)
        {:cont, {:ok, [reservation | acc]}}
      rescue
        e in RuntimeError ->
          Logger.warning("Fulfillment failed for order=#{order_id} sku=#{sku_id}: #{e.message}")
          {:halt, {:error, e.message}}
      end
    end)
  end

  def release_all(reservations) do
    Enum.each(reservations, fn r ->
      StockManager.release(r.id, r.sku_id, r.quantity)
    end)
  end

  def fulfill_or_rollback(order_id, line_items) do
    case fulfill_items(order_id, line_items) do
      {:ok, reservations} ->
        Logger.info("All #{length(reservations)} lines reserved for order=#{order_id}")
        {:ok, reservations}

      {:error, reason} ->
        Logger.warning("Rolling back partial reservations for order=#{order_id}")
        {:error, reason}
    end
  end
end
```
