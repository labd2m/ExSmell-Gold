# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Logistics.Shipments.create_shipment/13` |
| **Affected function(s)** | `create_shipment/13` |
| **Short explanation** | Thirteen parameters covering sender, recipient, package details, and service options are passed individually. Grouping them into `%Address{}`, `%Package{}`, and `%ShipmentOptions{}` structs would make call sites readable and eliminate the risk of mixing up positionally similar arguments like `sender_city` and `recipient_city`. |

```elixir
defmodule Logistics.Shipments do
  @moduledoc """
  Handles shipment creation and dispatch in the logistics pipeline.
  """

  require Logger

  @carriers ~w(fedex dhl ups correios)
  @weight_limit_kg 70

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because the function accepts 13 positional
  # arguments that describe two addresses, a package, and service options.
  # It is trivially easy to swap sender_city with recipient_city or mix up
  # weight_kg with declared_value. A %Shipment{} or separate address/package
  # structs would eliminate these risks and shorten the signature.
  def create_shipment(
        sender_name,
        sender_address,
        sender_city,
        sender_postal_code,
        recipient_name,
        recipient_address,
        recipient_city,
        recipient_postal_code,
        weight_kg,
        declared_value,
        carrier,
        insured,
        express_delivery
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_carrier(carrier),
         :ok <- validate_weight(weight_kg),
         :ok <- validate_declared_value(declared_value),
         {:ok, rate} <- fetch_rate(carrier, weight_kg, express_delivery, insured) do
      shipment = %{
        id: new_tracking_number(),
        sender: %{
          name: sender_name,
          address: sender_address,
          city: sender_city,
          postal_code: sender_postal_code
        },
        recipient: %{
          name: recipient_name,
          address: recipient_address,
          city: recipient_city,
          postal_code: recipient_postal_code
        },
        package: %{
          weight_kg: weight_kg,
          declared_value: declared_value,
          insured: insured
        },
        carrier: carrier,
        express_delivery: express_delivery,
        rate: rate,
        status: :pending,
        created_at: DateTime.utc_now()
      }

      case persist_shipment(shipment) do
        {:ok, saved} ->
          Logger.info("Shipment #{saved.id} created via #{carrier}")
          notify_sender(saved)
          {:ok, saved}

        {:error, reason} ->
          Logger.error("Failed to persist shipment: #{inspect(reason)}")
          {:error, :persistence_failure}
      end
    end
  end

  defp validate_carrier(c) when c in @carriers, do: :ok
  defp validate_carrier(c), do: {:error, "unknown carrier: #{c}"}

  defp validate_weight(w) when w > 0 and w <= @weight_limit_kg, do: :ok
  defp validate_weight(w) when w > @weight_limit_kg,
    do: {:error, "weight #{w} kg exceeds limit of #{@weight_limit_kg} kg"}
  defp validate_weight(_), do: {:error, "weight must be positive"}

  defp validate_declared_value(v) when v >= 0, do: :ok
  defp validate_declared_value(_), do: {:error, "declared_value must be non-negative"}

  defp fetch_rate(carrier, weight_kg, express, insured) do
    base = weight_kg * 4.50
    express_surcharge = if express, do: base * 0.40, else: 0.0
    insurance_fee = if insured, do: 12.0, else: 0.0
    total = base + express_surcharge + insurance_fee

    Logger.debug("Rate for #{carrier}: #{total}")
    {:ok, Float.round(total, 2)}
  end

  defp persist_shipment(shipment) do
    {:ok, Map.put(shipment, :persisted_at, DateTime.utc_now())}
  end

  defp notify_sender(shipment) do
    Logger.debug("Notifying sender for shipment #{shipment.id}")
    :ok
  end

  defp new_tracking_number do
    prefix = "SHP"
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16()
    "#{prefix}-#{suffix}"
  end
end
```
