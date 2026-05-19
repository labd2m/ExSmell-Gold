```elixir
defmodule ShipmentTracker do
  use GenServer

  @moduledoc """
  Tracks the lifecycle of a single shipment from dispatch to delivery.
  Records checkpoints, estimated arrival updates, and carrier events.
  """

  @enforce_keys [:shipment_id, :origin, :destination, :carrier]
  defstruct [
    :shipment_id,
    :origin,
    :destination,
    :carrier,
    :status,
    :eta,
    checkpoints: [],
    events: []
  ]

  def start(%{shipment_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def record_checkpoint(shipment_id, checkpoint) do
    GenServer.call(via(shipment_id), {:checkpoint, checkpoint})
  end

  def update_eta(shipment_id, eta) do
    GenServer.cast(via(shipment_id), {:update_eta, eta})
  end

  def mark_delivered(shipment_id) do
    GenServer.call(via(shipment_id), :deliver)
  end

  def current_state(shipment_id) do
    GenServer.call(via(shipment_id), :state)
  end

  defp via(id), do: {:via, Registry, {ShipmentRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{shipment_id: id, origin: origin, destination: destination, carrier: carrier} = attrs) do
    state = %__MODULE__{
      shipment_id: id,
      origin: origin,
      destination: destination,
      carrier: carrier,
      status: :in_transit,
      eta: Map.get(attrs, :eta)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:checkpoint, %{location: loc, timestamp: ts} = cp}, _from, state) do
    updated = %{state | checkpoints: [cp | state.checkpoints]}
    event = %{type: :checkpoint, location: loc, at: ts}
    {:reply, :ok, %{updated | events: [event | state.events]}}
  end

  def handle_call(:deliver, _from, state) do
    now = DateTime.utc_now()
    event = %{type: :delivered, at: now}
    updated = %{state | status: :delivered, events: [event | state.events]}
    {:reply, {:ok, updated}, updated}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:update_eta, eta}, state) do
    {:noreply, %{state | eta: eta}}
  end
end

defmodule LogisticsCoordinator do
  @moduledoc """
  Receives a list of shipment manifests and starts a tracker for each one.
  """

  def track_shipments(manifests) when is_list(manifests) do
    Enum.map(manifests, fn manifest ->
      case ShipmentTracker.start(manifest) do
        {:ok, _pid} ->
          {:started, manifest.shipment_id}

        {:error, {:already_started, _pid}} ->
          {:already_tracking, manifest.shipment_id}

        {:error, reason} ->
          {:failed, manifest.shipment_id, reason}
      end
    end)
  end

  def checkpoint_all(shipment_ids, checkpoint) do
    Enum.each(shipment_ids, fn id ->
      ShipmentTracker.record_checkpoint(id, checkpoint)
    end)
  end

  def deliver_all(shipment_ids) do
    Enum.map(shipment_ids, fn id ->
      {id, ShipmentTracker.mark_delivered(id)}
    end)
  end
end
```
