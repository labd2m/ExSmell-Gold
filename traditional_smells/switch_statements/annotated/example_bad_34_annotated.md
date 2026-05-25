# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `CarrierPolicy.delivery_sla_days/1` and `CarrierPolicy.max_package_weight_kg/1`
- **Affected functions:** `delivery_sla_days/1`, `max_package_weight_kg/1`
- **Short explanation:** The same `case` branching over carrier atom (`:fedex`, `:ups`, `:dhl`, `:usps`, `:local_courier`) is duplicated in both functions. Adding a new carrier requires updating both case expressions.

---

```elixir
defmodule CarrierPolicy do
  @moduledoc """
  Defines carrier-specific SLA commitments, weight restrictions,
  and rate structures used when selecting shipping options
  at checkout in an e-commerce fulfilment system.
  """

  alias CarrierPolicy.{Package, Address, RateQuote}

  @type carrier :: :fedex | :ups | :dhl | :usps | :local_courier

  @spec eligible_carriers(Package.t(), Address.t()) :: [carrier()]
  def eligible_carriers(%Package{weight_kg: weight} = package, %Address{} = destination) do
    all_carriers()
    |> Enum.filter(&(weight <= max_package_weight_kg(&1)))
    |> Enum.filter(&carrier_serves_destination?(&1, destination))
  end

  @spec quote_shipment(Package.t(), Address.t(), carrier()) ::
          {:ok, RateQuote.t()} | {:error, String.t()}
  def quote_shipment(%Package{} = package, %Address{} = address, carrier) do
    with :ok <- validate_weight(package, carrier),
         sla = delivery_sla_days(carrier),
         {:ok, rate} <- calculate_rate(package, address, carrier) do
      {:ok,
       %RateQuote{
         carrier: carrier,
         rate_usd: rate,
         sla_days: sla,
         estimated_delivery: estimate_delivery_date(sla)
       }}
    end
  end

  @spec compare_carriers(Package.t(), Address.t()) :: [RateQuote.t()]
  def compare_carriers(%Package{} = package, %Address{} = address) do
    eligible = eligible_carriers(package, address)

    eligible
    |> Enum.map(&quote_shipment(package, address, &1))
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, quote} -> quote end)
    |> Enum.sort_by(& &1.rate_usd)
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `carrier`
  # also appears in `max_package_weight_kg/1` below. Both enumerate :fedex, :ups,
  # :dhl, :usps, :local_courier — a new carrier must be added in both places.
  @spec delivery_sla_days(carrier()) :: integer()
  def delivery_sla_days(carrier) do
    case carrier do
      :fedex         -> 2
      :ups           -> 3
      :dhl           -> 4
      :usps          -> 5
      :local_courier -> 1
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `carrier`
  # already appeared in `delivery_sla_days/1` above. The carrier atoms are
  # fully duplicated here, forcing double maintenance whenever carriers change.
  @spec max_package_weight_kg(carrier()) :: float()
  def max_package_weight_kg(carrier) do
    case carrier do
      :fedex         -> 68.0
      :ups           -> 70.0
      :dhl           -> 70.0
      :usps          -> 31.75
      :local_courier -> 20.0
    end
  end
  # VALIDATION: SMELL END

  @spec validate_weight(Package.t(), carrier()) :: :ok | {:error, String.t()}
  defp validate_weight(%Package{weight_kg: weight}, carrier) do
    max = max_package_weight_kg(carrier)

    if weight <= max do
      :ok
    else
      {:error, "package weight #{weight}kg exceeds #{carrier} limit of #{max}kg"}
    end
  end

  @spec carrier_serves_destination?(carrier(), Address.t()) :: boolean()
  defp carrier_serves_destination?(:local_courier, %Address{country: country}) do
    country == "US"
  end

  defp carrier_serves_destination?(_carrier, _address), do: true

  @spec all_carriers() :: [carrier()]
  defp all_carriers, do: [:fedex, :ups, :dhl, :usps, :local_courier]

  @spec estimate_delivery_date(integer()) :: Date.t()
  defp estimate_delivery_date(sla_days) do
    Date.add(Date.utc_today(), sla_days)
  end

  @spec calculate_rate(Package.t(), Address.t(), carrier()) ::
          {:ok, float()} | {:error, String.t()}
  defp calculate_rate(%Package{weight_kg: weight}, %Address{country: country}, carrier) do
    base = weight * 3.5
    international_surcharge = if country != "US", do: base * 0.30, else: 0.0
    sla_factor = 10.0 / delivery_sla_days(carrier)
    {:ok, Float.round(base + international_surcharge + sla_factor, 2)}
  end
end
```
