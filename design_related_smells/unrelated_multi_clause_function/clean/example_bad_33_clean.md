```elixir
defmodule WarehouseRouter do
  @moduledoc """
  Routing engine for warehouse operations across the fulfilment centre.
  Manages pick-list assignments, inbound receiving dock allocation,
  and outbound carrier lane routing.
  """

  alias WarehouseRouter.{
    PickListAssignment,
    ReceivingDockRequest,
    CarrierLaneRequest,
    PickerRegistry,
    DockManager,
    LaneManager,
    ZoneOptimizer,
    FulfillmentStore,
    InboundStore,
    OutboundStore,
    FloorNotifier
  }

  require Logger

  @doc """
  Route a warehouse operation to the appropriate resource.

  Accepts a `%PickListAssignment{}`, `%ReceivingDockRequest{}`, or
  `%CarrierLaneRequest{}` and allocates the corresponding warehouse resource.

  ## Examples

      iex> WarehouseRouter.route(%PickListAssignment{order_id: "ord_001", zone: :zone_a})
      {:ok, %{picker_id: "wkr_12", estimated_pick_minutes: 8}}

  """
  def route(%PickListAssignment{
        order_id: order_id,
        pick_items: items,
        zone: zone,
        priority: priority
      }) do
    with {:ok, order} <- FulfillmentStore.find_order(order_id),
         :ok <- validate_order_ready_to_pick(order),
         {:ok, optimized_path} <- ZoneOptimizer.plan_route(zone, items),
         {:ok, picker} <- PickerRegistry.find_available(zone, priority),
         {:ok, pick_list} <-
           FulfillmentStore.create_pick_list(%{
             order_id: order_id,
             picker_id: picker.id,
             items: optimized_path,
             zone: zone,
             priority: priority,
             assigned_at: DateTime.utc_now()
           }),
         :ok <- FloorNotifier.notify_picker(picker.device_id, pick_list),
         est_minutes = estimate_pick_time(optimized_path) do
      Logger.info("Pick list for order #{order_id} assigned to picker #{picker.id} in #{zone}")
      {:ok, %{picker_id: picker.id, pick_list_id: pick_list.id, estimated_pick_minutes: est_minutes}}
    end
  end

  # route inbound receiving dock for arriving shipment
  def route(%ReceivingDockRequest{
        inbound_shipment_id: shipment_id,
        carrier: carrier,
        pallet_count: pallet_count,
        arrival_eta: eta
      }) do
    with {:ok, shipment} <- InboundStore.find(shipment_id),
         :ok <- validate_shipment_expected(shipment),
         {:ok, dock} <- DockManager.allocate(%{
           carrier: carrier,
           pallet_count: pallet_count,
           eta: eta,
           duration_minutes: estimate_unload_time(pallet_count)
         }),
         {:ok, updated} <-
           InboundStore.update(shipment_id, %{
             dock_id: dock.id,
             dock_number: dock.number,
             dock_allocated_at: DateTime.utc_now()
           }),
         :ok <- FloorNotifier.broadcast_dock_assignment(dock.number, shipment_id, carrier, eta) do
      Logger.info("Inbound shipment #{shipment_id} allocated to dock #{dock.number}")
      {:ok, %{dock_id: dock.id, dock_number: dock.number}}
    end
  end

  # route outbound order to appropriate carrier lane based on service level
  def route(%CarrierLaneRequest{
        outbound_order_id: order_id,
        carrier: carrier,
        service_level: service_level,
        cutoff_at: cutoff_at
      }) do
    with {:ok, order} <- OutboundStore.find(order_id),
         :ok <- validate_packed(order),
         {:ok, lane} <-
           LaneManager.assign(%{
             carrier: carrier,
             service_level: service_level,
             cutoff_at: cutoff_at
           }),
         :ok <- validate_before_cutoff(cutoff_at),
         {:ok, updated} <-
           OutboundStore.update(order_id, %{
             lane_id: lane.id,
             lane_number: lane.number,
             lane_assigned_at: DateTime.utc_now(),
             status: :ready_for_dispatch
           }),
         :ok <- FloorNotifier.notify_lane_assignment(lane.number, order_id, carrier) do
      Logger.info("Order #{order_id} routed to lane #{lane.number} for carrier #{carrier}")
      {:ok, %{lane_id: lane.id, lane_number: lane.number}}
    end
  end

  defp validate_order_ready_to_pick(%{status: :ready_to_pick}), do: :ok
  defp validate_order_ready_to_pick(%{status: s}), do: {:error, {:not_ready_to_pick, s}}

  defp validate_shipment_expected(%{status: :expected}), do: :ok
  defp validate_shipment_expected(%{status: :arrived}), do: :ok
  defp validate_shipment_expected(%{status: s}), do: {:error, {:shipment_not_expected, s}}

  defp validate_packed(%{status: :packed}), do: :ok
  defp validate_packed(%{status: s}), do: {:error, {:not_packed, s}}

  defp validate_before_cutoff(cutoff_at) do
    if DateTime.compare(DateTime.utc_now(), cutoff_at) == :lt do
      :ok
    else
      {:error, :carrier_cutoff_passed}
    end
  end

  defp estimate_pick_time(path), do: length(path) * 2
  defp estimate_unload_time(pallet_count), do: max(15, pallet_count * 3)
end
```
