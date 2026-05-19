# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `LocationManagerAgent` — `Agent` running warehouse slot allocation logic
- **Affected function(s):** `assign_location/3`, `release_location/2`, `transfer/3`
- **Short explanation:** Slot assignment, compatibility checks, capacity enforcement, and transfer coordination are business workflows that belong in a `GenServer`. The `Agent` here acts as a full business logic server.

```elixir
defmodule MyApp.LocationManagerAgent do
  @moduledoc """
  Manages warehouse bin/slot allocation for inbound and stored goods.
  Handles assignment, release, and cross-location transfers.
  """

  use Agent

  alias MyApp.{Repo, AuditLog}
  alias MyApp.Warehouse.{Location, Assignment, TransferRecord}

  @zone_capacity %{a: 200, b: 150, c: 100, d: 50}

  def start_link(_opts) do
    locations = Repo.all(Location) |> Enum.into(%{}, &{&1.id, &1})
    assignments = Repo.all(Assignment) |> Enum.into(%{}, &{&1.location_id, &1})

    Agent.start_link(
      fn -> %{locations: locations, assignments: assignments, transfers: []} end,
      name: __MODULE__
    )
  end

  def get_location(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.locations, id) end)
  end

  def available_in_zone(zone) do
    Agent.get(__MODULE__, fn state ->
      state.locations
      |> Map.values()
      |> Enum.filter(&(&1.zone == zone and not Map.has_key?(state.assignments, &1.id)))
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent is used to implement complex
  # warehouse slot management: it enforces zone capacity limits, validates SKU
  # compatibility, persists assignments to a database, logs audit trails, and
  # coordinates multi-location transfers. This level of orchestrated, side-effectful
  # business logic far exceeds the simple shared-state purpose of an Agent and
  # belongs in a GenServer.

  def assign_location(location_id, sku, quantity) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, location} <- Map.fetch(state.locations, location_id),
           false <- Map.has_key?(state.assignments, location_id),
           :ok <- check_zone_capacity(state, location.zone, quantity),
           :ok <- check_sku_compatibility(location, sku) do
        assignment = %Assignment{
          id: Ecto.UUID.generate(),
          location_id: location_id,
          sku: sku,
          quantity: quantity,
          assigned_at: DateTime.utc_now()
        }

        case Repo.insert(assignment) do
          {:ok, saved} ->
            AuditLog.record(:location_assigned, %{location_id: location_id, sku: sku, qty: quantity})
            new_state = put_in(state, [:assignments, location_id], saved)
            {{:ok, saved}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      else
        :error -> {{:error, :location_not_found}, state}
        true -> {{:error, :location_occupied}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  def release_location(location_id, released_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.assignments, location_id) do
        :error ->
          {{:error, :not_assigned}, state}

        {:ok, assignment} ->
          Repo.delete!(assignment)
          AuditLog.record(:location_released, %{location_id: location_id, by: released_by})
          new_state = %{state | assignments: Map.delete(state.assignments, location_id)}
          {{:ok, :released}, new_state}
      end
    end)
  end

  def transfer(from_location_id, to_location_id, quantity) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, from_assignment} <- Map.fetch(state.assignments, from_location_id),
           false <- Map.has_key?(state.assignments, to_location_id),
           true <- quantity <= from_assignment.quantity do
        {:ok, to_location} = Map.fetch(state.locations, to_location_id)

        with :ok <- check_zone_capacity(state, to_location.zone, quantity),
             :ok <- check_sku_compatibility(to_location, from_assignment.sku) do
          transfer_record = %TransferRecord{
            id: Ecto.UUID.generate(),
            from_location_id: from_location_id,
            to_location_id: to_location_id,
            sku: from_assignment.sku,
            quantity: quantity,
            transferred_at: DateTime.utc_now()
          }

          remaining = from_assignment.quantity - quantity
          updated_from = %{from_assignment | quantity: remaining}

          new_assignment = %Assignment{
            id: Ecto.UUID.generate(),
            location_id: to_location_id,
            sku: from_assignment.sku,
            quantity: quantity,
            assigned_at: DateTime.utc_now()
          }

          Repo.transaction(fn ->
            Repo.update!(updated_from)
            Repo.insert!(new_assignment)
            Repo.insert!(transfer_record)
          end)

          AuditLog.record(:location_transfer, %{
            from: from_location_id,
            to: to_location_id,
            qty: quantity
          })

          new_assignments =
            state.assignments
            |> Map.put(from_location_id, updated_from)
            |> Map.put(to_location_id, new_assignment)

          new_state = %{
            state
            | assignments: new_assignments,
              transfers: [transfer_record | state.transfers]
          }

          {{:ok, transfer_record}, new_state}
        end
      else
        :error -> {{:error, :source_not_assigned}, state}
        true -> {{:error, :destination_occupied}, state}
        false -> {{:error, :insufficient_quantity}, state}
      end
    end)
  end

  # VALIDATION: SMELL END

  defp check_zone_capacity(state, zone, qty) do
    cap = Map.get(@zone_capacity, zone, 50)
    current = state.assignments |> Map.values() |> Enum.map(& &1.quantity) |> Enum.sum()
    if current + qty <= cap, do: :ok, else: {:error, :zone_at_capacity}
  end

  defp check_sku_compatibility(%Location{allowed_skus: nil}, _sku), do: :ok
  defp check_sku_compatibility(%Location{allowed_skus: allowed}, sku) do
    if sku in allowed, do: :ok, else: {:error, :sku_not_allowed}
  end
end
```
