# Annotated Example 02 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `ShipmentTracker.start/1`
- **Affected function(s):** `start/1`
- **Short explanation:** Each shipment spawns its own GenServer via `GenServer.start/3`, entirely outside a supervision tree. In a logistics system with thousands of concurrent shipments, these processes are invisible to the application's fault-tolerance mechanisms and cannot be automatically recovered after a crash.

```elixir
defmodule ShipmentTracker do
  use GenServer

  @moduledoc """
  Tracks the real-time state of an individual shipment, including
  location updates, status transitions, and delivery ETA.
  One process is created per active shipment.
  """

  @status_transitions %{
    :pending => [:picked_up],
    :picked_up => [:in_transit, :failed],
    :in_transit => [:out_for_delivery, :failed],
    :out_for_delivery => [:delivered, :failed],
    :delivered => [],
    :failed => [:pending]
  }

  defstruct [
    :shipment_id,
    :origin,
    :destination,
    :carrier,
    :status,
    :current_location,
    :eta,
    :events
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a long-running
  # shipment-tracking process with no supervisor parent. In production there may be
  # thousands of simultaneous shipments. If any process crashes due to a bad location
  # update or carrier callback, the shipment tracking is silently lost and the
  # process is never restarted.
  def start(%{shipment_id: id} = attrs) do
    state = struct!(__MODULE__, Map.merge(attrs, %{status: :pending, events: []}))
    GenServer.start(__MODULE__, state, name: via_name(id))
  end
  # VALIDATION: SMELL END

  def update_location(shipment_id, location) do
    GenServer.cast(via_name(shipment_id), {:update_location, location})
  end

  def transition_status(shipment_id, new_status) do
    GenServer.call(via_name(shipment_id), {:transition, new_status})
  end

  def update_eta(shipment_id, eta) do
    GenServer.cast(via_name(shipment_id), {:update_eta, eta})
  end

  def get_state(shipment_id) do
    GenServer.call(via_name(shipment_id), :get_state)
  end

  def get_events(shipment_id) do
    GenServer.call(via_name(shipment_id), :get_events)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, record_event(state, :initialized, %{status: :pending})}
  end

  @impl true
  def handle_call({:transition, new_status}, _from, state) do
    allowed = Map.get(@status_transitions, state.status, [])

    if new_status in allowed do
      new_state =
        state
        |> Map.put(:status, new_status)
        |> record_event(:status_changed, %{from: state.status, to: new_status})

      {:reply, {:ok, new_state.status}, new_state}
    else
      {:reply, {:error, :invalid_transition}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  @impl true
  def handle_cast({:update_location, location}, state) do
    new_state =
      state
      |> Map.put(:current_location, location)
      |> record_event(:location_updated, %{location: location})

    {:noreply, new_state}
  end

  def handle_cast({:update_eta, eta}, state) do
    new_state =
      state
      |> Map.put(:eta, eta)
      |> record_event(:eta_updated, %{eta: eta})

    {:noreply, new_state}
  end

  defp record_event(state, type, metadata) do
    event = %{
      type: type,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }

    Map.update!(state, :events, &[event | &1])
  end

  defp via_name(shipment_id) do
    {:via, Registry, {ShipmentTracker.Registry, shipment_id}}
  end
end
```
