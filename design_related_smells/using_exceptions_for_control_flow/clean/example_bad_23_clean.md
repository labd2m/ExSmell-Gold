```elixir
defmodule InventoryStore do
  @moduledoc """
  Manages stock levels and reservations for warehouse SKUs.
  Intended to be used by order processing and fulfillment pipelines.
  """

  defmodule OutOfStockError do
    defexception [:message, :sku, :requested, :available]
  end

  defmodule InvalidSkuError do
    defexception [:message, :sku]
  end

  defmodule InvalidQuantityError do
    defexception [:message]
  end

  @stock %{
    "SKU-1001" => 120,
    "SKU-1002" => 3,
    "SKU-1003" => 0,
    "SKU-2001" => 55,
    "SKU-2002" => 8
  }

  def reserve(sku, quantity, order_id) when not is_binary(sku) or sku == "" do
    raise InvalidSkuError,
      message: "SKU must be a non-empty string, got: #{inspect(sku)}",
      sku: sku
  end

  def reserve(_sku, quantity, _order_id) when not is_integer(quantity) or quantity <= 0 do
    raise InvalidQuantityError,
      message: "Quantity must be a positive integer, got: #{inspect(quantity)}"
  end

  def reserve(sku, quantity, order_id) do
    available = Map.get(@stock, sku)

    if is_nil(available) do
      raise InvalidSkuError,
        message: "SKU '#{sku}' does not exist in the inventory catalogue",
        sku: sku
    end

    if available < quantity do
      raise OutOfStockError,
        message: "Insufficient stock for SKU '#{sku}' on order #{order_id}",
        sku: sku,
        requested: quantity,
        available: available
    end

    reservation_id = generate_reservation_id(sku, order_id)

    %{
      reservation_id: reservation_id,
      sku: sku,
      quantity_reserved: quantity,
      order_id: order_id,
      reserved_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
    }
  end

  defp generate_reservation_id(sku, order_id) do
    "RES-#{sku}-#{order_id}-#{System.unique_integer([:positive])}"
  end
end

defmodule OrderFulfillment do
  @moduledoc """
  Orchestrates inventory reservation for line items in customer orders.
  """

  require Logger

  def allocate_items(%{id: order_id, line_items: line_items} = order) do
    Logger.info("Starting inventory allocation for order #{order_id}")

    results =
      Enum.map(line_items, fn item ->
        # try...rescue to deal with everyday stock availability checks.
        # Out-of-stock is not an exceptional event; it should be handled with
        # normal control-flow constructs like `case`.
        try do
          reservation = InventoryStore.reserve(item.sku, item.quantity, order_id)
          Logger.debug("Reserved #{item.quantity}x #{item.sku} → #{reservation.reservation_id}")
          {:ok, reservation}
        rescue
          e in InventoryStore.OutOfStockError ->
            Logger.warning(
              "Out of stock: SKU #{e.sku}, requested #{e.requested}, available #{e.available}"
            )
            {:error, {:out_of_stock, item.sku, e.available}}

          e in InventoryStore.InvalidSkuError ->
            Logger.error("Invalid SKU in order #{order_id}: #{e.message}")
            {:error, {:invalid_sku, item.sku}}

          e in InventoryStore.InvalidQuantityError ->
            Logger.error("Invalid quantity for SKU #{item.sku}: #{e.message}")
            {:error, {:invalid_quantity, item.sku}}
        end
      end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(failures) do
      reservations = Enum.map(results, fn {:ok, r} -> r end)
      Logger.info("All #{length(reservations)} items reserved for order #{order_id}")
      {:ok, Map.put(order, :reservations, reservations)}
    else
      Logger.warning("Allocation failed for order #{order_id}: #{length(failures)} item(s) unavailable")
      {:error, {:partial_failure, failures}}
    end
  end

  def release_reservations(reservations) do
    Enum.each(reservations, fn r ->
      Logger.info("Releasing reservation #{r.reservation_id} for SKU #{r.sku}")
    end)
  end
end
```
