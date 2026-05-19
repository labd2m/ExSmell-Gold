# Annotated Example 07 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `RideRequest`, `DriverMatcher`, `FareCalculator`, and `TripAudit` all interact directly with the Agent PID
- **Affected functions:** `RideRequest.create/3`, `DriverMatcher.assign/3`, `FareCalculator.compute/2`, `TripAudit.record_completion/2`
- **Short explanation:** A trip state is stored in an Agent, but four modules across the ride-hailing domain all call `Agent.update/2` and `Agent.get/2` directly. Each module writes different fields into the same map without coordination, producing a fragile and undocumented shared state.

---

```elixir
defmodule RideRequest do
  @moduledoc """
  Creates and tracks ride requests from passengers.
  """

  def new(passenger_id, pickup, dropoff) do
    {:ok, pid} = Agent.start_link(fn ->
      %{
        passenger_id: passenger_id,
        pickup: pickup,
        dropoff: dropoff,
        status: :requested,
        requested_at: DateTime.utc_now()
      }
    end)
    {:ok, pid}
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because RideRequest directly calls
  # Agent.update/2 to change the trip status and embed notes.
  # No module owns the Agent API — any caller can modify the trip state
  # in any format it chooses.
  def cancel(pid, reason) do
    Agent.update(pid, fn state ->
      %{state | status: :cancelled, cancellation_reason: reason, cancelled_at: DateTime.utc_now()}
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def get_status(pid) do
    Agent.get(pid, fn state -> state.status end)
  end
end

defmodule DriverMatcher do
  @moduledoc """
  Assigns available drivers to incoming ride requests.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DriverMatcher directly calls
  # Agent.update/2 to inject driver information into the trip state.
  # It assumes the map structure created by RideRequest and adds new
  # keys without any ownership or schema enforcement.
  def assign(pid, driver_id, vehicle_info) do
    Agent.update(pid, fn state ->
      %{state |
        status: :driver_assigned,
        driver_id: driver_id,
        vehicle: vehicle_info,
        assigned_at: DateTime.utc_now()
      }
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def unassign(pid) do
    Agent.update(pid, fn state ->
      state
      |> Map.delete(:driver_id)
      |> Map.delete(:vehicle)
      |> Map.put(:status, :requested)
    end)
    :ok
  end

  def assigned_driver(pid) do
    Agent.get(pid, fn state -> Map.get(state, :driver_id) end)
  end
end

defmodule FareCalculator do
  @moduledoc """
  Computes fares for completed or estimated trips.
  """

  @base_fare Decimal.new("2.50")
  @per_km_rate Decimal.new("1.10")

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because FareCalculator directly reads from and
  # writes to the Agent state with Agent.get/2 and Agent.update/2, embedding
  # fare details into the same map managed by the other modules. It must
  # know about the :pickup and :dropoff keys written by RideRequest.
  def compute(pid, distance_km) do
    state = Agent.get(pid, fn s -> s end)

    fare =
      @base_fare
      |> Decimal.add(Decimal.mult(@per_km_rate, Decimal.new(distance_km)))

    surge =
      case state.status do
        :driver_assigned -> Decimal.new("1.0")
        _ -> Decimal.new("1.5")
      end

    total = Decimal.mult(fare, surge)

    Agent.update(pid, fn s ->
      %{s | fare: total, distance_km: distance_km, fare_computed_at: DateTime.utc_now()}
    end)

    {:ok, total}
  end
  # VALIDATION: SMELL END
end

defmodule TripAudit do
  @moduledoc """
  Records trip completion details and generates audit entries.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because TripAudit calls Agent.update/2
  # and Agent.get/2 directly, reading the whole trip state written by
  # RideRequest, DriverMatcher, and FareCalculator — creating a hidden
  # dependency on every field name across all three modules.
  def record_completion(pid, rating) do
    Agent.update(pid, fn state ->
      %{state | status: :completed, passenger_rating: rating, completed_at: DateTime.utc_now()}
    end)
    :ok
  end

  def trip_summary(pid) do
    Agent.get(pid, fn state ->
      %{
        trip_id: Map.get(state, :trip_id, "unknown"),
        passenger: state.passenger_id,
        driver: Map.get(state, :driver_id),
        pickup: state.pickup,
        dropoff: state.dropoff,
        fare: Map.get(state, :fare),
        distance_km: Map.get(state, :distance_km),
        status: state.status,
        rating: Map.get(state, :passenger_rating)
      }
    end)
  end
  # VALIDATION: SMELL END
end
```
