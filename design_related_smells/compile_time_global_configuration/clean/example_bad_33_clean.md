```elixir
defmodule Logistics.ShippingRouter do
  @moduledoc """
  Routes outbound shipments to the appropriate carrier based on
  package dimensions, weight, destination, and configured preferences.
  Supports rate-quoting and label generation across multiple carriers.
  """

  require Logger

  @preferred_carrier Application.fetch_env!(:logistics, :preferred_carrier)

  @supported_carriers [:fedex, :ups, :dhl, :usps]
  @max_weight_kg 70
  @dimensional_divisor 5_000

  @type package :: %{
          weight_kg: float(),
          length_cm: float(),
          width_cm: float(),
          height_cm: float()
        }

  @type address :: %{
          name: String.t(),
          street: String.t(),
          city: String.t(),
          state: String.t(),
          postal_code: String.t(),
          country: String.t()
        }

  @type carrier :: :fedex | :ups | :dhl | :usps

  @spec book_shipment(package(), address()) ::
          {:ok, %{tracking_number: String.t(), carrier: carrier(), label_url: String.t()}}
          | {:error, atom()}
  def book_shipment(package, destination) do
    with :ok <- validate_package(package),
         carrier = select_carrier(package, destination),
         {:ok, label} <- create_label(carrier, package, destination) do
      Logger.info("Shipment booked",
        carrier: carrier,
        tracking: label.tracking_number,
        destination: destination.postal_code
      )

      {:ok, label}
    end
  end

  @spec get_rate_quote(package(), address()) ::
          {:ok, [%{carrier: carrier(), price_cents: integer(), eta_days: integer()}]}
          | {:error, atom()}
  def get_rate_quote(package, destination) do
    with :ok <- validate_package(package) do
      quotes =
        @supported_carriers
        |> Enum.map(&quote_from_carrier(&1, package, destination))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort_by(& &1.price_cents)

      if quotes == [], do: {:error, :no_quotes_available}, else: {:ok, quotes}
    end
  end

  @spec select_carrier(package(), address()) :: carrier()
  def select_carrier(package, destination) do
    cond do
      international?(destination) -> :dhl
      heavy?(package) -> :fedex
      true -> @preferred_carrier
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_package(%{weight_kg: w}) when w > @max_weight_kg do
    {:error, :package_too_heavy}
  end

  defp validate_package(%{weight_kg: w, length_cm: l, width_cm: wi, height_cm: h})
       when w > 0 and l > 0 and wi > 0 and h > 0 do
    :ok
  end

  defp validate_package(_), do: {:error, :invalid_package}

  defp create_label(carrier, package, destination) do
    carrier_adapter(carrier).create_label(package, destination)
  end

  defp quote_from_carrier(carrier, package, destination) do
    carrier_adapter(carrier).get_rate(package, destination)
  rescue
    _ -> {:error, :adapter_error}
  end

  defp carrier_adapter(:fedex), do: Logistics.Carriers.FedEx
  defp carrier_adapter(:ups), do: Logistics.Carriers.UPS
  defp carrier_adapter(:dhl), do: Logistics.Carriers.DHL
  defp carrier_adapter(:usps), do: Logistics.Carriers.USPS

  defp international?(%{country: country}) when country != "US", do: true
  defp international?(_), do: false

  defp heavy?(%{weight_kg: w}), do: w > 30

  defp volumetric_weight(%{length_cm: l, width_cm: w, height_cm: h}) do
    l * w * h / @dimensional_divisor
  end

  defp billable_weight(package) do
    max(package.weight_kg, volumetric_weight(package))
  end
end
```
