# Annotated Example 12 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Logistics.Shipments.schedule_shipment/10` |
| **Affected function(s)** | `schedule_shipment/10` |
| **Explanation** | The function takes 10 positional arguments representing the origin address, destination address, parcel dimensions/weight, and scheduling options. These arguments naturally form two or three cohesive structures (e.g., `%Address{}`, `%Parcel{}`, `%ShipmentOptions{}`), but are instead passed as an unwieldy flat list of parameters. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `schedule_shipment/10` accepts ten
# positional parameters. The first four (origin_*) describe an origin address,
# the next four (dest_*) describe a destination address, and the remaining two
# are shipping options. Grouping them into address structs and an options map
# would make each call site readable and prevent argument-order mistakes.
defmodule Logistics.Shipments do
  @moduledoc """
  Provides shipment scheduling and carrier selection for the logistics subsystem.
  """

  require Logger

  alias Logistics.Repo
  alias Logistics.Schemas.Shipment
  alias Logistics.CarrierClient
  alias Logistics.RateCalculator

  @supported_carriers [:fedex, :ups, :dhl]
  @default_carrier :fedex

  def schedule_shipment(
        origin_street,
        origin_city,
        origin_state,
        origin_zip,
        dest_street,
        dest_city,
        dest_state,
        dest_zip,
        carrier,
        priority
      ) do
# VALIDATION: SMELL END
    carrier = if carrier in @supported_carriers, do: carrier, else: @default_carrier

    origin = %{
      street: origin_street,
      city: origin_city,
      state: origin_state,
      zip: origin_zip
    }

    destination = %{
      street: dest_street,
      city: dest_city,
      state: dest_state,
      zip: dest_zip
    }

    with :ok <- validate_address(origin, :origin),
         :ok <- validate_address(destination, :destination) do
      rate = RateCalculator.estimate(origin, destination, carrier, priority)

      tracking_number = generate_tracking_number(carrier)

      shipment_attrs = %{
        origin_street: origin_street,
        origin_city: origin_city,
        origin_state: origin_state,
        origin_zip: origin_zip,
        dest_street: dest_street,
        dest_city: dest_city,
        dest_state: dest_state,
        dest_zip: dest_zip,
        carrier: carrier,
        priority: priority,
        rate: rate,
        tracking_number: tracking_number,
        status: :scheduled,
        scheduled_at: DateTime.utc_now()
      }

      case Repo.insert(Shipment.changeset(%Shipment{}, shipment_attrs)) do
        {:ok, shipment} ->
          CarrierClient.register(carrier, shipment)
          Logger.info("Shipment #{shipment.id} scheduled via #{carrier}, tracking: #{tracking_number}")
          {:ok, shipment}

        {:error, changeset} ->
          Logger.error("Shipment creation failed: #{inspect(changeset.errors)}")
          {:error, :scheduling_failed}
      end
    end
  end

  defp validate_address(%{street: s, city: c, state: st, zip: z}, label) do
    cond do
      blank?(s) -> {:error, {label, :missing_street}}
      blank?(c) -> {:error, {label, :missing_city}}
      blank?(st) -> {:error, {label, :missing_state}}
      not Regex.match?(~r/^\d{5}(-\d{4})?$/, z) -> {:error, {label, :invalid_zip}}
      true -> :ok
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  defp generate_tracking_number(carrier) do
    prefix =
      case carrier do
        :fedex -> "FX"
        :ups -> "UP"
        :dhl -> "DH"
      end

    suffix =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16()

    "#{prefix}-#{suffix}"
  end
end
```
