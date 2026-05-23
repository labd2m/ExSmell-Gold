```elixir
defmodule Logistics.ManifestBuilder do
  @moduledoc """
  Assembles export manifests for outbound freight shipments.
  A manifest groups parcels belonging to a single dispatch run
  into a structured document for customs and carrier handoff.
  """

  alias Logistics.{Shipment, Parcel, Carrier, Address}

  @weight_precision 3
  @max_hazmat_un_digits 4


  @doc """
  Builds a complete manifest map for the given shipment.
  Raises if the shipment does not exist or has not been confirmed.
  """
  @spec build(String.t()) :: map()
  def build(shipment_id) do
    shipment = Shipment.get!(shipment_id)
    :confirmed = shipment.status

    parcels     = Shipment.list_parcels(shipment)
    dispatcher  = Shipment.get_dispatcher(shipment)

    %{
      manifest_number:   generate_manifest_number(shipment),
      shipment_ref:      shipment.reference_code,
      dispatched_at:     shipment.scheduled_dispatch_at,
      dispatcher_name:   dispatcher.full_name,
      dispatcher_badge:  dispatcher.employee_id,
      parcel_count:      length(parcels),
      total_gross_kg:    total_weight(parcels),
      entries:           Enum.map(parcels, &build_parcel_entry/1),
      certifications:    required_certifications(parcels)
    }
  end


  defp build_parcel_entry(parcel) do
    carrier     = Parcel.get_carrier(parcel)
    origin      = Parcel.get_origin_address(parcel)
    destination = Parcel.get_destination_address(parcel)
    hazmat      = Parcel.hazmat_classification(parcel)
    customs     = Parcel.customs_description(parcel)

    %{
      tracking_number:   parcel.tracking_number,
      carrier_code:      carrier.iata_code,
      carrier_name:      carrier.display_name,
      service_level:     Carrier.service_label(carrier, parcel.service_code),
      origin_port:       origin.port_of_loading,
      origin_country:    Address.iso_country(origin),
      destination_port:  destination.port_of_discharge,
      destination_country: Address.iso_country(destination),
      gross_weight_kg:   format_weight(parcel.gross_weight_kg),
      dimensions_cm:     "#{parcel.length_cm}×#{parcel.width_cm}×#{parcel.height_cm}",
      declared_value_usd: parcel.declared_value_usd,
      insurance_required: parcel.insurance_required,
      hazmat_un_number:  pad_un_number(hazmat),
      customs_description: customs
    }
  end

  defp total_weight(parcels) do
    parcels
    |> Enum.map(& &1.gross_weight_kg)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> Decimal.round(@weight_precision)
  end

  defp required_certifications(parcels) do
    parcels
    |> Enum.flat_map(&Parcel.required_certifications/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp generate_manifest_number(shipment) do
    date_part = Calendar.strftime(shipment.scheduled_dispatch_at, "%Y%m%d")
    "MNF-#{date_part}-#{shipment.id |> String.slice(0, 8) |> String.upcase()}"
  end

  defp format_weight(%Decimal{} = kg) do
    kg
    |> Decimal.round(@weight_precision)
    |> Decimal.to_string(:normal)
  end

  defp pad_un_number(nil),   do: nil
  defp pad_un_number(un_num) do
    un_num
    |> Integer.to_string()
    |> String.pad_leading(@max_hazmat_un_digits, "0")
    |> then(&"UN#{&1}")
  end
end
```
