# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `ShipmentTracker`, `WarehouseWorker`, `CarrierAdapter`, and `TrackingDashboard`
- **Affected functions:** `ShipmentTracker.register/2`, `WarehouseWorker.mark_dispatched/2`, `CarrierAdapter.update_location/3`, `TrackingDashboard.current_status/2`
- **Short explanation:** Direct `Agent` interactions are scattered across four modules, each reading from or writing to the shared shipment state agent without a centralised interface, making the internal state format implicitly shared.

```elixir
defmodule ShipmentStore do
  @moduledoc "Starts the shared Agent holding in-flight shipment state."

  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :initial, %{shipments: %{}, events: []})
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because ShipmentTracker directly calls Agent.update to write
# new shipment entries into the shared state, taking ownership over the internal map format
# without any centralised API module.
defmodule ShipmentTracker do
  @moduledoc "Registers new shipments into the system."

  require Logger

  @default_carrier :unassigned

  def register(agent, attrs) do
    id = Map.fetch!(attrs, :id)
    origin = Map.fetch!(attrs, :origin)
    destination = Map.fetch!(attrs, :destination)
    weight_kg = Map.get(attrs, :weight_kg, 0.0)

    shipment = %{
      id: id,
      origin: origin,
      destination: destination,
      weight_kg: weight_kg,
      carrier: @default_carrier,
      status: :registered,
      location: origin,
      registered_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | shipments: Map.put(state.shipments, id, shipment)}
    end)

    Logger.info("Registered shipment #{id} from #{origin} to #{destination}")
    {:ok, id}
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because WarehouseWorker directly calls Agent.update to
# transition shipment status, duplicating awareness of the shipments map structure.
defmodule WarehouseWorker do
  @moduledoc "Handles warehouse-side dispatch operations."

  require Logger

  def mark_dispatched(agent, shipment_id) do
    Agent.update(agent, fn state ->
      case Map.fetch(state.shipments, shipment_id) do
        {:ok, shipment} ->
          event = %{shipment_id: shipment_id, event: :dispatched, at: DateTime.utc_now()}
          updated = %{shipment | status: :in_transit, dispatched_at: DateTime.utc_now()}

          %{
            state
            | shipments: Map.put(state.shipments, shipment_id, updated),
              events: [event | state.events]
          }

        :error ->
          Logger.warning("Attempted dispatch on unknown shipment #{shipment_id}")
          state
      end
    end)

    :ok
  end

  def receive_return(agent, shipment_id, reason) do
    Agent.update(agent, fn state ->
      case Map.fetch(state.shipments, shipment_id) do
        {:ok, shipment} ->
          event = %{
            shipment_id: shipment_id,
            event: :returned,
            reason: reason,
            at: DateTime.utc_now()
          }

          updated = %{shipment | status: :returned}
          %{state | shipments: Map.put(state.shipments, shipment_id, updated), events: [event | state.events]}

        :error ->
          state
      end
    end)
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because CarrierAdapter directly calls Agent.update to
# mutate the location and carrier fields on a shipment, spreading state mutation logic
# yet further across unrelated modules.
defmodule CarrierAdapter do
  @moduledoc "Syncs carrier tracking updates into internal shipment state."

  require Logger

  @known_carriers [:dhl, :fedex, :ups, :local_courier]

  def update_location(agent, shipment_id, %{carrier: carrier, location: location} = update) do
    unless carrier in @known_carriers do
      Logger.warning("Unknown carrier #{carrier} for shipment #{shipment_id}")
    end

    arrived = Map.get(update, :arrived, false)

    Agent.update(agent, fn state ->
      case Map.fetch(state.shipments, shipment_id) do
        {:ok, shipment} ->
          new_status = if arrived, do: :delivered, else: :in_transit
          event = %{shipment_id: shipment_id, event: :location_update, location: location, at: DateTime.utc_now()}

          updated = %{shipment | carrier: carrier, location: location, status: new_status}

          %{
            state
            | shipments: Map.put(state.shipments, shipment_id, updated),
              events: [event | state.events]
          }

        :error ->
          Logger.error("Carrier update for unknown shipment #{shipment_id}")
          state
      end
    end)

    :ok
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because TrackingDashboard directly calls Agent.get to read
# raw internal state, coupling UI/reporting logic directly to the Agent data structure.
defmodule TrackingDashboard do
  @moduledoc "Renders current shipment status for operators."

  def current_status(agent, shipment_id) do
    Agent.get(agent, fn state ->
      Map.get(state.shipments, shipment_id)
    end)
  end

  def all_in_transit(agent) do
    Agent.get(agent, fn state ->
      state.shipments
      |> Map.values()
      |> Enum.filter(&(&1.status == :in_transit))
    end)
  end

  def recent_events(agent, limit \\ 20) do
    Agent.get(agent, fn state ->
      Enum.take(state.events, limit)
    end)
  end
end
# VALIDATION: SMELL END
```
