# Annotated Example 02: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Logistics.ShipmentProcessor.build_shipping_label/1`
- **Affected Function(s)**: `build_shipping_label/1`
- **Explanation**: `build_shipping_label/1` exclusively accesses functions and data from
  the `Package` module (`Package.dimensions/1`, `Package.gross_weight/1`,
  `Package.declared_value/1`, `Package.fragile?/1`, `Package.hazmat_class/1`,
  `Package.description/1`). It has no reliance on `ShipmentProcessor`'s own data or
  behavior, so it would be more cohesive inside the `Package` module.

## Code

```elixir
defmodule Logistics.ShipmentProcessor do
  require Logger

  alias Logistics.{Shipment, Carrier}
  alias Logistics.Package

  @label_version "2.1"

  @doc """
  Processes an outbound shipment: validates it, selects a carrier,
  registers with the carrier, and generates the shipping label.
  """
  def process_outbound(shipment_id) do
    shipment = Shipment.get!(shipment_id)

    with :ok <- validate_shipment(shipment),
         {:ok, carrier} <- Carrier.select_for_shipment(shipment),
         {:ok, tracking} <- Carrier.register_shipment(carrier, shipment),
         {:ok, label} <- generate_label(shipment, carrier, tracking) do
      Shipment.mark_processed(shipment, %{
        carrier_id: carrier.id,
        tracking_number: tracking.number,
        label_url: label.url
      })
    else
      {:error, reason} ->
        Logger.error("Shipment #{shipment_id} processing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Retries all shipments that previously failed processing.
  """
  def retry_failed_shipments do
    Shipment.list_failed()
    |> Enum.each(fn shipment ->
      case process_outbound(shipment.id) do
        {:ok, _} ->
          Logger.info("Shipment #{shipment.id} successfully reprocessed.")

        {:error, reason} ->
          Logger.warning("Retry failed for shipment #{shipment.id}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Returns a summary of all pending shipments.
  """
  def pending_summary do
    Shipment.list_pending()
    |> Enum.map(fn s ->
      %{id: s.id, destination: s.destination_address, created_at: s.inserted_at}
    end)
  end

  defp validate_shipment(shipment) do
    cond do
      is_nil(shipment.destination_address) -> {:error, :missing_destination}
      shipment.status != :pending -> {:error, :invalid_status}
      is_nil(shipment.package_id) -> {:error, :missing_package}
      true -> :ok
    end
  end

  defp generate_label(shipment, carrier, tracking) do
    package = Package.get!(shipment.package_id)
    label_data = build_shipping_label(package)
    Carrier.create_label(carrier, tracking, label_data)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because build_shipping_label/1 exclusively accesses functions
  # VALIDATION: and data from the Package module: Package.dimensions/1, Package.gross_weight/1,
  # VALIDATION: Package.declared_value/1, Package.fragile?/1, Package.hazmat_class/1,
  # VALIDATION: and Package.description/1. It has no reliance on ShipmentProcessor's own
  # VALIDATION: data or behavior, so it would be more cohesive inside the Package module.
  defp build_shipping_label(package) do
    dimensions = Package.dimensions(package)
    weight = Package.gross_weight(package)
    declared_value = Package.declared_value(package)
    is_fragile = Package.fragile?(package)
    hazmat = Package.hazmat_class(package)
    description = Package.description(package)

    %{
      label_version: @label_version,
      dimensions: %{
        length: dimensions.length,
        width: dimensions.width,
        height: dimensions.height,
        unit: dimensions.unit
      },
      weight: %{value: weight.value, unit: weight.unit},
      declared_value: declared_value,
      handling_instructions: %{
        fragile: is_fragile,
        hazmat_class: hazmat
      },
      contents_description: description
    }
  end
  # VALIDATION: SMELL END

  defp mark_as_failed(shipment_id, reason) do
    case Shipment.get(shipment_id) do
      {:ok, shipment} -> Shipment.mark_failed(shipment, reason)
      _ -> :ok
    end
  end
end
```
