```elixir
defmodule MyApp.Shipping.LabelPrinter do
  @moduledoc """
  Generates shipping labels by calling carrier APIs.
  Applies address normalization, carrier-account selection, and label format preferences.
  """

  alias MyApp.Shipping.{CarrierAccount, LabelRecord}
  alias MyApp.Geo.Address
  alias MyApp.Carriers.{FedExClient, UPSClient, DHLClient}

  @label_dpi 300

  def generate(shipment_id, carrier_id) do
    with {:ok, shipment} <- fetch_shipment(shipment_id) do
      address  = Address.validate(shipment.destination)
      account  = CarrierAccount.find(carrier_id)

      is_residential = address.residential
      is_po_box      = address.po_box
      country        = address.country_iso

      api_key        = account.api_key
      account_number = account.account_number
      label_format   = account.label_format

      cond do
        is_po_box and carrier_id not in [:usps, :canada_post] ->
          {:error, :po_box_not_supported}

        is_residential and carrier_id == :freight_direct ->
          {:error, :residential_not_supported}

        not international_allowed?(carrier_id, country) ->
          {:error, :international_not_supported}

        true ->
          request_label(shipment, carrier_id, api_key, account_number, label_format)
      end
    end
  end

  def reprint(label_id) do
    case LabelRecord.fetch(label_id) do
      nil    -> {:error, :not_found}
      record -> {:ok, record.label_data}
    end
  end

  def void(label_id) do
    case LabelRecord.fetch(label_id) do
      nil    -> {:error, :not_found}
      %{status: :voided} -> {:error, :already_voided}
      record ->
        case call_void_api(record) do
          :ok ->
            updated = %{record | status: :voided, voided_at: DateTime.utc_now()}
            LabelRecord.save(updated)
            {:ok, updated}
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_for_shipment(shipment_id) do
    :ets.tab2list(:labels)
    |> Enum.map(fn {_, l} -> l end)
    |> Enum.filter(&(&1.shipment_id == shipment_id))
    |> Enum.sort_by(& &1.created_at)
  end


  defp request_label(shipment, carrier_id, api_key, account_number, format) do
    params = %{
      account:    account_number,
      format:     format,
      dpi:        @label_dpi,
      from:       shipment.origin_address,
      to:         shipment.destination,
      weight_kg:  shipment.weight_kg,
      service:    shipment.service_level
    }

    result =
      case carrier_id do
        :fedex -> FedExClient.create_label(api_key, params)
        :ups   -> UPSClient.create_label(api_key, params)
        :dhl   -> DHLClient.create_label(api_key, params)
        _      -> {:error, :unsupported_carrier}
      end

    case result do
      {:ok, label_data} ->
        record = %{
          id:          generate_id(),
          shipment_id: shipment.id,
          carrier_id:  carrier_id,
          label_data:  label_data,
          status:      :active,
          created_at:  DateTime.utc_now()
        }
        LabelRecord.save(record)
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp international_allowed?(carrier_id, country) do
    domestic_only = [:usps_media_mail, :freight_direct]
    country == "US" or carrier_id not in domestic_only
  end

  defp call_void_api(%{carrier_id: :fedex} = r), do: FedExClient.void_label(r.label_data.tracking)
  defp call_void_api(%{carrier_id: :ups}   = r), do: UPSClient.void_label(r.label_data.tracking)
  defp call_void_api(_), do: :ok

  defp fetch_shipment(id) do
    case :ets.lookup(:shipments, id) do
      [{_, s}] -> {:ok, s}
      []       -> {:error, :not_found}
    end
  end

  defp generate_id do
    "LBL-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
