# Annotated Example 33 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Shipping.RateCalculator` declarations
- **Affected functions:** `Shipping.RateCalculator.calculate/2`, `Shipping.RateCalculator.cheapest_option/2`, `Shipping.RateCalculator.estimate_delivery_date/3`, `Shipping.RateCalculator.surcharges/2`, `Shipping.RateCalculator.compare_carriers/2`
- **Short explanation:** Two separate source files both declare `defmodule Shipping.RateCalculator`. BEAM drops one of the definitions at load time, silently removing functions that shipping cost estimates depend on, potentially causing incorrect charges or runtime crashes in the checkout flow.

---

```elixir
# ── file: lib/shipping/rate_calculator.ex ───────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Shipping.RateCalculator` is declared
# here and again in a second block below. BEAM will discard one definition,
# making rate calculation functions permanently unavailable.

defmodule Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates and delivery estimates for multiple carriers.
  Defined in `lib/shipping/rate_calculator.ex`.
  """

  alias Shipping.{CarrierAdapter, ZoneTable, WeightTier, SurchargePolicy}

  @carriers [:fedex, :ups, :usps, :dhl]
  @dimensional_weight_divisor 139.0

  @type address :: %{
    street: String.t(),
    city: String.t(),
    state: String.t(),
    zip: String.t(),
    country: String.t()
  }

  @type parcel :: %{
    weight_oz: float(),
    length_in: float(),
    width_in: float(),
    height_in: float()
  }

  @type rate :: %{
    carrier: atom(),
    service_level: String.t(),
    rate_cents: pos_integer(),
    estimated_days: pos_integer()
  }

  @doc "Fetch available shipping rates for a parcel from all carriers."
  @spec calculate(parcel(), address()) :: {:ok, [rate()]} | {:error, String.t()}
  def calculate(parcel, destination) do
    billable_weight = billable_weight(parcel)
    zone = ZoneTable.lookup(destination.zip)

    rates =
      @carriers
      |> Enum.flat_map(fn carrier ->
        case CarrierAdapter.get_rates(carrier, billable_weight, zone, destination) do
          {:ok, carrier_rates} -> carrier_rates
          {:error, _} -> []
        end
      end)
      |> Enum.map(fn rate ->
        surcharge = SurchargePolicy.for_carrier(rate.carrier, parcel, destination)
        %{rate | rate_cents: rate.rate_cents + surcharge}
      end)

    {:ok, rates}
  end

  @doc "Return the lowest-cost available rate option."
  @spec cheapest_option(parcel(), address()) :: {:ok, rate()} | {:error, String.t()}
  def cheapest_option(parcel, destination) do
    with {:ok, [_ | _] = rates} <- calculate(parcel, destination) do
      {:ok, Enum.min_by(rates, & &1.rate_cents)}
    else
      {:ok, []} -> {:error, "No rates available for destination"}
      err -> err
    end
  end

  @doc "Estimate delivery date for a given carrier and service level."
  @spec estimate_delivery_date(atom(), String.t(), Date.t()) :: Date.t()
  def estimate_delivery_date(carrier, service_level, ship_date) do
    days = CarrierAdapter.transit_days(carrier, service_level)
    business_days_from(ship_date, days)
  end

  @doc "Return itemised surcharges for a parcel shipment."
  @spec surcharges(parcel(), address()) :: [%{name: String.t(), amount_cents: integer()}]
  def surcharges(parcel, destination) do
    @carriers
    |> Enum.flat_map(fn carrier ->
      SurchargePolicy.itemise(carrier, parcel, destination)
    end)
    |> Enum.uniq_by(& &1.name)
  end

  @doc "Compare rates from two specific carriers side by side."
  @spec compare_carriers(atom(), atom()) :: (parcel(), address() -> map())
  def compare_carriers(carrier_a, carrier_b) do
    fn parcel, destination ->
      ra = CarrierAdapter.get_rates(carrier_a, billable_weight(parcel), nil, destination)
      rb = CarrierAdapter.get_rates(carrier_b, billable_weight(parcel), nil, destination)
      %{carrier_a => ra, carrier_b => rb}
    end
  end

  defp billable_weight(%{weight_oz: w, length_in: l, width_in: wi, height_in: h}) do
    dimensional = l * wi * h / @dimensional_weight_divisor
    max(w / 16.0, dimensional)
  end

  defp business_days_from(date, days) do
    Enum.reduce(1..days, date, fn _, d ->
      next = Date.add(d, 1)
      if Date.day_of_week(next) in [6, 7], do: Date.add(next, 2), else: next
    end)
  end
end

# VALIDATION: SMELL END

# ── file: lib/shipping/rate_calculator_cache.ex  (caching layer added in a
#    separate file; developer forgot to namespace under a sub-module) ──────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Shipping.RateCalculator` replaces the
# first in BEAM. All rate calculation functions from the first block become
# permanently unavailable, causing errors at checkout.

defmodule Shipping.RateCalculator do
  @moduledoc """
  Caching wrapper for shipping rate lookups to reduce carrier API calls.
  Was intended to be `Shipping.RateCalculator.Cache` but was accidentally
  named the same as the core calculator module.
  """

  alias Shipping.RateCache

  @cache_ttl_seconds 300

  @doc "Fetch rates with caching; falls through to the live API on cache miss."
  @spec cached_rates(map(), map()) :: {:ok, [map()]} | {:error, String.t()}
  def cached_rates(parcel, destination) do
    key = cache_key(parcel, destination)

    case RateCache.get(key) do
      {:ok, rates} ->
        {:ok, rates}

      :miss ->
        with {:ok, rates} <- live_rates(parcel, destination) do
          RateCache.put(key, rates, ttl: @cache_ttl_seconds)
          {:ok, rates}
        end
    end
  end

  @doc "Invalidate all cached rates for a specific destination ZIP."
  @spec invalidate_zip(String.t()) :: :ok
  def invalidate_zip(zip) do
    RateCache.delete_prefix("rates:#{zip}:")
  end

  @doc "Return cache hit statistics for the rate calculator."
  @spec cache_stats() :: map()
  def cache_stats do
    %{
      hits: RateCache.stat(:hits),
      misses: RateCache.stat(:misses),
      hit_rate: RateCache.stat(:hit_rate)
    }
  end

  defp cache_key(parcel, destination) do
    parcel_sig =
      [parcel.weight_oz, parcel.length_in, parcel.width_in, parcel.height_in]
      |> Enum.map_join(":", &Float.to_string/1)

    "rates:#{destination.zip}:#{parcel_sig}"
  end

  defp live_rates(parcel, destination) do
    Shipping.CarrierAdapter.fetch_all(parcel, destination)
  end
end

# VALIDATION: SMELL END
```
