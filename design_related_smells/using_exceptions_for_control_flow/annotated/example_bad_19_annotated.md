# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Warehouse.LocationAssigner.assign/2`
- **Affected function(s):** `Warehouse.LocationAssigner.assign/2` (library side); `Warehouse.InboundReceiver.receive_pallet/2` (client side)
- **Explanation:** `assign/2` raises `RuntimeError` for expected warehouse-management outcomes: unknown pallet ID, pallet already placed, no compatible location available, and weight capacity exceeded. These are foreseeable daily events in a warehouse operation. The receiving workflow must handle them as regular outcomes — for example, to route a pallet to overflow — but with only `try/rescue` available, exception handling becomes the sole control-flow option.

```elixir
defmodule Warehouse.Pallet do
  @moduledoc "Represents a pallet arriving at the warehouse."

  @enforce_keys [:id, :sku_id, :unit_count, :weight_kg, :status]
  defstruct [:id, :sku_id, :unit_count, :weight_kg, :status, :hazmat, :temperature_class]
end

defmodule Warehouse.Location do
  @moduledoc "A physical storage location within the warehouse."

  @enforce_keys [:id, :zone, :aisle, :bay, :max_weight_kg, :available]
  defstruct [:id, :zone, :aisle, :bay, :max_weight_kg, :current_weight_kg, :available, :pallet_id]

  def free_capacity(%__MODULE__{max_weight_kg: max, current_weight_kg: current}) do
    max - (current || 0)
  end
end

defmodule Warehouse.PalletStore do
  @moduledoc "In-memory pallet registry."

  alias Warehouse.Pallet

  @pallets %{
    "PLT-001" => %Pallet{id: "PLT-001", sku_id: "SKU-A", unit_count: 48, weight_kg: 320.0, status: :inbound},
    "PLT-002" => %Pallet{id: "PLT-002", sku_id: "SKU-B", unit_count: 24, weight_kg: 180.0, status: :placed},
    "PLT-003" => %Pallet{id: "PLT-003", sku_id: "SKU-C", unit_count: 60, weight_kg: 950.0, status: :inbound}
  }

  def find(id), do: Map.fetch(@pallets, id)
  def mark_placed(id), do: {:ok, Map.get(@pallets, id)}
end

defmodule Warehouse.LocationStore do
  @moduledoc "In-memory location registry."

  alias Warehouse.Location

  @locations [
    %Location{id: "A01-01", zone: "A", aisle: "01", bay: "01", max_weight_kg: 500.0, current_weight_kg: 0.0, available: true},
    %Location{id: "A01-02", zone: "A", aisle: "01", bay: "02", max_weight_kg: 500.0, current_weight_kg: 480.0, available: true},
    %Location{id: "B02-01", zone: "B", aisle: "02", bay: "01", max_weight_kg: 750.0, current_weight_kg: 0.0, available: false, pallet_id: "PLT-999"}
  ]

  def available_locations, do: Enum.filter(@locations, & &1.available)

  def assign_location(location_id, pallet_id, weight_kg) do
    {:ok, %{location_id: location_id, pallet_id: pallet_id, weight: weight_kg}}
  end
end

defmodule Warehouse.LocationAssigner do
  @moduledoc """
  Assigns an inbound pallet to a suitable storage location.
  Checks pallet status, weight capacity, and location availability.
  """

  alias Warehouse.{Location, LocationStore, PalletStore}
  require Logger

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `assign/2` raises RuntimeError for four
  # VALIDATION: expected warehouse-operations outcomes: unknown pallet, pallet
  # VALIDATION: already placed, no location with sufficient capacity, and weight
  # VALIDATION: exceeding the chosen location's limit. The inbound receiving
  # VALIDATION: workflow processes many pallets and needs to handle each failure
  # VALIDATION: as a data outcome (e.g., route to overflow staging). Forcing
  # VALIDATION: try/rescue as the only available mechanism makes exceptions the
  # VALIDATION: de-facto control-flow for routine warehouse operations.
  def assign(pallet_id, opts \\ []) when is_binary(pallet_id) do
    preferred_zone = Keyword.get(opts, :preferred_zone)

    case PalletStore.find(pallet_id) do
      :error ->
        raise RuntimeError,
          message: "Pallet '#{pallet_id}' is not registered in the warehouse system"

      {:ok, pallet} ->
        if pallet.status == :placed do
          raise RuntimeError,
            message: "Pallet '#{pallet_id}' is already placed at a location"
        end

        candidates =
          LocationStore.available_locations()
          |> Enum.filter(fn loc ->
            (is_nil(preferred_zone) or loc.zone == preferred_zone) and
              Location.free_capacity(loc) >= pallet.weight_kg
          end)

        if Enum.empty?(candidates) do
          raise RuntimeError,
            message:
              "No available location can accommodate pallet '#{pallet_id}' " <>
                "(weight: #{pallet.weight_kg} kg). Consider overflow staging."
        end

        chosen = Enum.min_by(candidates, &Location.free_capacity/1)

        if Location.free_capacity(chosen) < pallet.weight_kg do
          raise RuntimeError,
            message:
              "Location '#{chosen.id}' can only hold #{Location.free_capacity(chosen)} kg " <>
                "but pallet '#{pallet_id}' weighs #{pallet.weight_kg} kg"
        end

        {:ok, assignment} = LocationStore.assign_location(chosen.id, pallet_id, pallet.weight_kg)
        PalletStore.mark_placed(pallet_id)

        Logger.info("Pallet #{pallet_id} assigned to location #{chosen.id}")
        %{pallet_id: pallet_id, location_id: chosen.id, zone: chosen.zone, assignment: assignment}
    end
  end
  # VALIDATION: SMELL END
end

defmodule Warehouse.InboundReceiver do
  @moduledoc """
  Orchestrates the inbound receiving process for a batch of pallets
  arriving from a delivery vehicle.
  """

  alias Warehouse.LocationAssigner
  require Logger

  def receive_pallet(pallet_id, opts \\ []) do
    # Client forced to use try/rescue because LocationAssigner.assign/2 raises
    # on all assignment failure conditions instead of returning {:error, reason}.
    try do
      assignment = LocationAssigner.assign(pallet_id, opts)

      Logger.info("Pallet #{pallet_id} received and placed at #{assignment.location_id}")
      {:ok, assignment}
    rescue
      e in RuntimeError ->
        Logger.warning("Could not place pallet #{pallet_id}: #{e.message}")
        {:error, %{pallet_id: pallet_id, reason: e.message}}
    end
  end

  def receive_batch(pallet_ids, opts \\ []) when is_list(pallet_ids) do
    Logger.info("Processing inbound batch of #{length(pallet_ids)} pallets")

    results = Enum.map(pallet_ids, fn pid -> {pid, receive_pallet(pid, opts)} end)

    placed = Enum.filter(results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)

    Logger.info("Batch complete: #{length(placed)} placed, #{length(failed)} failed")
    %{placed: placed, failed: failed}
  end
end
```
