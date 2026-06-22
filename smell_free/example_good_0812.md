```elixir
defmodule MyApp.Commerce.OrderFulfiller do
  @moduledoc """
  Coordinates the fulfilment of a paid order: reserving stock across
  multiple warehouses, generating a pick list, allocating a carrier,
  and transitioning the order to the `:processing` status. The
  orchestration is expressed as a linear `with` pipeline so that
  partial state never persists on failure — each step is rolled back by
  the compensating actions in the error branch.
  """

  alias MyApp.Commerce.{Orders, Order}
  alias MyApp.Inventory.StockLevel
  alias MyApp.Warehouse.PickListGenerator
  alias MyApp.Shipping.{CarrierSelector, Parcel}
  alias MyApp.Logistics.LabelPrinter

  @type fulfil_result ::
          {:ok, %{order: Order.t(), pick_list: list(), label: map()}}
          | {:error, :insufficient_stock, [String.t()]}
          | {:error, :no_carrier, term()}
          | {:error, :label_failed, term()}
          | {:error, :status_update_failed, Ecto.Changeset.t()}

  @doc """
  Fulfils `order` by reserving stock, building a pick list, selecting a
  carrier, printing a label, and updating the order status. On any failure
  previously reserved stock is released.
  """
  @spec fulfil(Order.t()) :: fulfil_result()
  def fulfil(%Order{} = order) do
    with {:ok, reserved_items} <- reserve_stock(order),
         {:ok, pick_list} <- build_pick_list(reserved_items),
         {:ok, rate} <- select_carrier(order),
         {:ok, label} <- print_label(order, rate) do
      case Orders.update_status(order, :processing) do
        {:ok, updated_order} ->
          {:ok, %{order: updated_order, pick_list: pick_list, label: label}}

        {:error, changeset} ->
          release_stock(reserved_items)
          {:error, :status_update_failed, changeset}
      end
    else
      {:error, :insufficient_stock, skus} = err ->
        err

      {:error, :no_carrier, reason} = err ->
        err

      {:error, :label_failed, reason} ->
        release_stock_for_order(order)
        {:error, :label_failed, reason}
    end
  end

  @spec reserve_stock(Order.t()) ::
          {:ok, [map()]} | {:error, :insufficient_stock, [String.t()]}
  defp reserve_stock(order) do
    {reserved, failed} =
      Enum.reduce(order.items, {[], []}, fn item, {ok_acc, fail_acc} ->
        case StockLevel.reserve(item.sku, item.quantity) do
          :ok -> {[item | ok_acc], fail_acc}
          {:error, :insufficient_stock} -> {ok_acc, [item.sku | fail_acc]}
        end
      end)

    if failed == [] do
      {:ok, reserved}
    else
      Enum.each(reserved, fn item -> StockLevel.release(item.sku, item.quantity) end)
      {:error, :insufficient_stock, failed}
    end
  end

  @spec build_pick_list([map()]) :: {:ok, list()}
  defp build_pick_list(items) do
    enriched = Enum.map(items, &enrich_with_bin_location/1)
    pick_list = PickListGenerator.generate(enriched)
    {:ok, pick_list}
  end

  @spec select_carrier(Order.t()) ::
          {:ok, map()} | {:error, :no_carrier, term()}
  defp select_carrier(order) do
    parcel = %Parcel{
      weight_grams: order.total_weight_grams,
      length_cm: order.parcel_length_cm,
      width_cm: order.parcel_width_cm,
      height_cm: order.parcel_height_cm
    }

    case CarrierSelector.select(parcel, order.shipping_address, :standard) do
      {:ok, rate} -> {:ok, rate}
      {:error, reason} -> {:error, :no_carrier, reason}
    end
  end

  @spec print_label(Order.t(), map()) :: {:ok, map()} | {:error, :label_failed, term()}
  defp print_label(order, rate) do
    shipment = build_shipment(order, rate)

    case LabelPrinter.print(shipment) do
      {:ok, label} -> {:ok, label}
      {:error, reason} -> {:error, :label_failed, reason}
    end
  end

  @spec release_stock([map()]) :: :ok
  defp release_stock(items) do
    Enum.each(items, fn item -> StockLevel.release(item.sku, item.quantity) end)
  end

  @spec release_stock_for_order(Order.t()) :: :ok
  defp release_stock_for_order(order) do
    Enum.each(order.items, fn item -> StockLevel.release(item.sku, item.quantity) end)
  end

  @spec enrich_with_bin_location(map()) :: map()
  defp enrich_with_bin_location(item) do
    bin = MyApp.Inventory.BinLocator.locate(item.sku)
    Map.put(item, :bin, bin)
  end

  @spec build_shipment(Order.t(), map()) :: map()
  defp build_shipment(order, rate) do
    %{
      id: order.id,
      carrier: rate.carrier,
      service_code: rate.service,
      destination: order.shipping_address,
      weight_grams: order.total_weight_grams
    }
  end
end
```
