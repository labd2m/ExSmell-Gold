# Annotated Example 02 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Logistics.Shipments.register_shipment/13`
- **Affected function(s):** `register_shipment/13`
- **Short explanation:** The function lists 13 individual parameters covering sender, receiver, package dimensions, and options. These naturally belong to grouped structs, and the flat list makes the call site fragile and hard to read.

---

```elixir
defmodule Logistics.Shipments do
  @moduledoc """
  Manages shipment registration and carrier assignment in the logistics platform.
  """

  require Logger

  alias Logistics.{Carrier, ShipmentRecord, TrackingService}

  @carriers [:fedex, :ups, :dhl, :usps]
  @max_weight_kg 70.0

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 13 positional parameters are used instead of
  # VALIDATION: grouping sender info, receiver info, and package specs into dedicated structs.
  def register_shipment(
        sender_name,
        sender_address,
        sender_city,
        sender_country,
        receiver_name,
        receiver_address,
        receiver_city,
        receiver_country,
        weight_kg,
        width_cm,
        height_cm,
        depth_cm,
        carrier
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_carrier(carrier),
         :ok <- validate_weight(weight_kg),
         :ok <- validate_dimensions(width_cm, height_cm, depth_cm),
         {:ok, rate} <- Carrier.fetch_rate(carrier, weight_kg, sender_country, receiver_country) do

      tracking_number = TrackingService.generate_tracking_number(carrier)

      record = %ShipmentRecord{
        tracking_number: tracking_number,
        carrier: carrier,
        sender: %{
          name: sender_name,
          address: sender_address,
          city: sender_city,
          country: sender_country
        },
        receiver: %{
          name: receiver_name,
          address: receiver_address,
          city: receiver_city,
          country: receiver_country
        },
        package: %{
          weight_kg: weight_kg,
          width_cm: width_cm,
          height_cm: height_cm,
          depth_cm: depth_cm,
          volume_cm3: width_cm * height_cm * depth_cm
        },
        rate: rate,
        status: :registered,
        registered_at: DateTime.utc_now()
      }

      case persist_shipment(record) do
        {:ok, saved} ->
          Logger.info("Shipment #{tracking_number} registered via #{carrier}")
          {:ok, saved}

        {:error, reason} ->
          Logger.error("Failed to register shipment: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def list_shipments_by_carrier(carrier) when carrier in @carriers do
    {:ok, []}
  end

  def cancel_shipment(tracking_number) do
    Logger.info("Cancelling shipment #{tracking_number}")
    :ok
  end

  defp validate_carrier(carrier) when carrier in @carriers, do: :ok
  defp validate_carrier(c), do: {:error, {:unsupported_carrier, c}}

  defp validate_weight(w) when is_float(w) and w > 0 and w <= @max_weight_kg, do: :ok
  defp validate_weight(w) when is_float(w) and w > @max_weight_kg,
    do: {:error, {:weight_exceeds_limit, w}}
  defp validate_weight(_), do: {:error, :invalid_weight}

  defp validate_dimensions(w, h, d)
       when is_number(w) and is_number(h) and is_number(d) and
              w > 0 and h > 0 and d > 0,
       do: :ok

  defp validate_dimensions(_, _, _), do: {:error, :invalid_dimensions}

  defp persist_shipment(record) do
    {:ok, record}
  end
end
```
