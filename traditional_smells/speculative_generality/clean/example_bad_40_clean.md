```elixir
defmodule Logistics.FulfillmentPlanner do
  @moduledoc """
  Builds fulfillment plans for outbound orders: assigns warehouse,
  selects pick strategy, and reserves inventory for each line item.
  """

  alias Logistics.{Order, WarehouseSelector, PickStrategy, InventoryReservation, FulfillmentPlan}

  require Logger

  @spec plan(Order.t()) :: {:ok, FulfillmentPlan.t()} | {:error, atom()}
  def plan(%Order{} = order) do
    with {:ok, warehouse} <- WarehouseSelector.select(order),
         {:ok, strategy} <- PickStrategy.determine(order, warehouse),
         {:ok, reservations} <- InventoryReservation.reserve_all(order.line_items, warehouse),
         {:ok, plan} <- FulfillmentPlan.create(order, warehouse, strategy, reservations) do
      Logger.info("Fulfillment plan created order=#{order.id} warehouse=#{warehouse.code}")
      {:ok, plan}
    else
      {:error, :insufficient_stock} ->
        Logger.warning("Cannot fulfill order=#{order.id}: insufficient stock")
        {:error, :insufficient_stock}

      {:error, reason} ->
        Logger.error("Fulfillment planning failed order=#{order.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec replan(String.t()) :: {:ok, FulfillmentPlan.t()} | {:error, atom()}
  def replan(order_id) do
    with {:ok, order} <- Order.fetch(order_id),
         :ok <- FulfillmentPlan.cancel_existing(order_id),
         {:ok, plan} <- plan(order) do
      Logger.info("Fulfillment re-planned order=#{order_id}")
      {:ok, plan}
    end
  end
end

defmodule Logistics.PackagingAdvisor do
  @moduledoc """
  Recommends optimal box sizes for shipment items to minimise
  dimensional weight charges applied by carriers.

  Box recommendations are based on item dimensions, fragility, and
  the carrier's dimensional weight divisor.
  """

  @box_catalogue [
    %{id: :xs, length: 15, width: 10, height: 5, max_weight_kg: 1.0},
    %{id: :sm, length: 25, width: 20, height: 10, max_weight_kg: 3.0},
    %{id: :md, length: 40, width: 30, height: 20, max_weight_kg: 8.0},
    %{id: :lg, length: 60, width: 40, height: 30, max_weight_kg: 20.0},
    %{id: :xl, length: 80, width: 60, height: 40, max_weight_kg: 40.0}
  ]

  @dim_weight_divisor 5_000

  @spec recommend([map()]) :: {:ok, map()} | {:error, atom()}
  def recommend(items) when is_list(items) and length(items) > 0 do
    total_volume = Enum.sum(Enum.map(items, &item_volume/1))
    total_weight = Enum.sum(Enum.map(items, & &1.weight_kg))
    has_fragile = Enum.any?(items, & &1.fragile)

    case find_box(total_volume, total_weight, has_fragile) do
      {:ok, box} ->
        dim_weight = calculate_dim_weight(box)

        {:ok,
         %{
           box_id: box.id,
           box_dimensions: %{l: box.length, w: box.width, h: box.height},
           total_item_volume_cm3: total_volume,
           actual_weight_kg: total_weight,
           dimensional_weight_kg: dim_weight,
           billable_weight_kg: max(total_weight, dim_weight),
           fragile_packing_required: has_fragile
         }}

      {:error, :no_box_fits} ->
        {:error, :no_suitable_box}
    end
  end

  def recommend([]), do: {:error, :no_items}

  defp find_box(volume, weight, fragile) do
    volume_with_buffer = if fragile, do: volume * 1.30, else: volume * 1.10

    result =
      Enum.find(@box_catalogue, fn box ->
        box_volume(box) >= volume_with_buffer and box.max_weight_kg >= weight
      end)

    case result do
      nil -> {:error, :no_box_fits}
      box -> {:ok, box}
    end
  end

  defp item_volume(%{length_cm: l, width_cm: w, height_cm: h}), do: l * w * h
  defp item_volume(_item), do: 0

  defp box_volume(%{length: l, width: w, height: h}), do: l * w * h

  defp calculate_dim_weight(box) do
    Float.round(box_volume(box) / @dim_weight_divisor, 3)
  end
end
```
