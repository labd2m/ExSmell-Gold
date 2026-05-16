```elixir
defmodule MyApp.Logistics.ShippingCalculator do
  @moduledoc """
  Calculates shipping quotes for domestic and international parcels based on
  carrier rate tables, dimensional weight rules, service levels, and surcharges.
  """

  require Logger

  alias MyApp.Logistics.{CarrierRateTable, SurchargeEngine, AddressValidator, ShipmentQuote}

  @dimensional_divisor 5000
  @fuel_surcharge_rate 0.085
  @residential_surcharge 4.25
  @remote_area_surcharge 12.50
  @supported_service_levels [:economy, :standard, :express, :overnight]

  @type quote_opts :: [
          service_level: atom(),
          length_cm: number(),
          width_cm: number(),
          height_cm: number(),
          is_residential: boolean(),
          insurance_value: number() | nil
        ]

  @spec quote(term(), map(), map(), quote_opts()) ::
          {:ok, ShipmentQuote.t()} | {:error, atom()}
  def quote(weight_kg, origin_address, destination_address, opts \\ []) do
    service_level = Keyword.get(opts, :service_level, :standard)
    is_residential = Keyword.get(opts, :is_residential, false)
    insurance_value = Keyword.get(opts, :insurance_value)

    length_cm = Keyword.get(opts, :length_cm)
    width_cm = Keyword.get(opts, :width_cm)
    height_cm = Keyword.get(opts, :height_cm)

    with :ok <- validate_service_level(service_level),
         {:ok, origin} <- AddressValidator.normalize(origin_address),
         {:ok, destination} <- AddressValidator.normalize(destination_address),
         {:ok, rate_table} <- CarrierRateTable.fetch(origin.zone, destination.zone, service_level) do

      dimensional_weight =
        if length_cm && width_cm && height_cm do
          length_cm * width_cm * height_cm / @dimensional_divisor
        else
          0
        end

      billable_weight = max(weight_kg, dimensional_weight)
      base_rate = compute_base_rate(billable_weight, rate_table)

      fuel_surcharge = Float.round(base_rate * @fuel_surcharge_rate, 2)
      residential_surcharge = if is_residential, do: @residential_surcharge, else: 0.0
      remote_surcharge = if destination.is_remote, do: @remote_area_surcharge, else: 0.0

      insurance_fee =
        if insurance_value, do: compute_insurance_fee(insurance_value), else: 0.0

      extra_surcharges =
        SurchargeEngine.evaluate(origin, destination, service_level, weight_kg)

      total =
        Enum.sum([
          base_rate,
          fuel_surcharge,
          residential_surcharge,
          remote_surcharge,
          insurance_fee,
          extra_surcharges
        ])
        |> Float.round(2)

      quote = %ShipmentQuote{
        service_level: service_level,
        weight_kg: weight_kg,
        billable_weight_kg: billable_weight,
        base_rate: base_rate,
        fuel_surcharge: fuel_surcharge,
        other_surcharges: residential_surcharge + remote_surcharge + extra_surcharges,
        insurance_fee: insurance_fee,
        total: total,
        currency: rate_table.currency,
        estimated_transit_days: rate_table.transit_days,
        quoted_at: DateTime.utc_now()
      }

      {:ok, quote}
    end
  end

  @spec batch_quote([map()], map(), atom()) :: [ShipmentQuote.t() | {:error, atom()}]
  def batch_quote(parcels, destination_address, service_level \\ :standard) do
    Enum.map(parcels, fn parcel ->
      case quote(parcel.weight_kg, parcel.origin_address, destination_address,
             service_level: service_level,
             length_cm: parcel[:length_cm],
             width_cm: parcel[:width_cm],
             height_cm: parcel[:height_cm]
           ) do
        {:ok, q} -> q
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec transit_time(map(), map(), atom()) :: {:ok, integer()} | {:error, atom()}
  def transit_time(origin, destination, service_level \\ :standard) do
    with {:ok, origin} <- AddressValidator.normalize(origin),
         {:ok, destination} <- AddressValidator.normalize(destination),
         {:ok, rate_table} <- CarrierRateTable.fetch(origin.zone, destination.zone, service_level) do
      {:ok, rate_table.transit_days}
    end
  end

  # Private helpers

  defp validate_service_level(sl) when sl in @supported_service_levels, do: :ok
  defp validate_service_level(_), do: {:error, :invalid_service_level}

  defp compute_base_rate(billable_weight, rate_table) do
    Float.round(billable_weight * rate_table.rate_per_kg + rate_table.base_fee, 2)
  end

  defp compute_insurance_fee(declared_value) when declared_value > 0 do
    Float.round(max(declared_value * 0.015, 2.50), 2)
  end

  defp compute_insurance_fee(_), do: 0.0
end
```
