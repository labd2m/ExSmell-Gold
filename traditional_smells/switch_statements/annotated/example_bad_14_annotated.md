# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `DeliveryRateCalculator` module — functions `base_rate_cents/1`, `max_weight_kg/1`, and `carrier_label/1`
- **Affected functions:** `base_rate_cents/1`, `max_weight_kg/1`, `carrier_label/1`
- **Short explanation:** The same `case delivery_method` branching over `:standard`, `:express`, `:overnight`, and `:freight` is duplicated across three functions. Adding a new delivery method requires updating each case block independently, which is the Switch Statements smell.

---

```elixir
defmodule DeliveryRateCalculator do
  @moduledoc """
  Calculates shipping costs for outbound orders based on the selected delivery
  method, package weight, and destination zone. Used by the order management
  system when presenting shipping options to customers at checkout.
  """

  require Logger

  @delivery_methods [:standard, :express, :overnight, :freight]

  def valid_delivery_methods, do: @delivery_methods

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over delivery_method
  # (:standard, :express, :overnight, :freight) is duplicated across base_rate_cents/1,
  # max_weight_kg/1, and carrier_label/1. Adding a new delivery method forces changes
  # to all three case blocks independently.

  @doc """
  Returns the base shipping rate in cents for the given delivery method,
  before weight and zone surcharges are applied.
  """
  def base_rate_cents(%{delivery_method: delivery_method}) do
    case delivery_method do
      :standard -> 499
      :express -> 1499
      :overnight -> 2999
      :freight -> 7500
      _ -> 499
    end
  end

  @doc """
  Returns the maximum package weight in kilograms accepted for this delivery method.
  Packages exceeding this limit must be moved to the `:freight` method.
  """
  def max_weight_kg(%{delivery_method: delivery_method}) do
    case delivery_method do
      :standard -> 30
      :express -> 20
      :overnight -> 15
      :freight -> 1_000
      _ -> 30
    end
  end

  @doc """
  Returns the marketing label shown to customers when selecting a shipping option.
  """
  def carrier_label(%{delivery_method: delivery_method}) do
    case delivery_method do
      :standard -> "Standard Shipping (5–7 business days)"
      :express -> "Express Shipping (2–3 business days)"
      :overnight -> "Overnight Delivery (next business day)"
      :freight -> "Freight Delivery (scheduled pickup)"
      _ -> "Shipping"
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Computes a per-kg weight surcharge for packages that exceed the free weight
  threshold for the selected delivery method.
  """
  def weight_surcharge_cents(%{delivery_method: method, weight_kg: weight_kg}) do
    free_threshold_kg = 5
    excess = max(0.0, weight_kg - free_threshold_kg)

    rate_per_kg =
      case method do
        :standard -> 20
        :express -> 45
        :overnight -> 80
        :freight -> 10
        _ -> 20
      end

    trunc(excess * rate_per_kg)
  end

  @doc """
  Calculates a zone-based distance surcharge. Zone 1 is local, Zone 3 is national.
  """
  def zone_surcharge_cents(%{delivery_method: method}, zone) when zone in 1..3 do
    base = base_rate_cents(%{delivery_method: method})
    multiplier = (zone - 1) * 0.15
    trunc(base * multiplier)
  end

  def zone_surcharge_cents(_, _zone), do: 0

  @doc """
  Validates that the package weight does not exceed the method's limit.
  """
  def weight_valid?(%{delivery_method: _method} = shipment, weight_kg) do
    weight_kg <= max_weight_kg(shipment)
  end

  @doc """
  Calculates the full shipping quote for a shipment, including all surcharges.
  """
  def quote(%{delivery_method: _method} = shipment, weight_kg, zone) do
    if not weight_valid?(shipment, weight_kg) do
      {:error, {:weight_exceeds_limit, max_weight_kg(shipment)}}
    else
      shipment_with_weight = Map.put(shipment, :weight_kg, weight_kg)
      base = base_rate_cents(shipment)
      weight_extra = weight_surcharge_cents(shipment_with_weight)
      zone_extra = zone_surcharge_cents(shipment, zone)
      total_cents = base + weight_extra + zone_extra

      {:ok,
       %{
         delivery_method: shipment.delivery_method,
         label: carrier_label(shipment),
         base_rate_cents: base,
         weight_surcharge_cents: weight_extra,
         zone_surcharge_cents: zone_extra,
         total_cents: total_cents,
         total_dollars: total_cents / 100.0
       }}
    end
  end

  @doc """
  Returns all available shipping quotes for a package, sorted cheapest first.
  """
  def all_quotes(weight_kg, zone) do
    @delivery_methods
    |> Enum.map(fn method ->
      quote(%{delivery_method: method}, weight_kg, zone)
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, q} -> q end)
    |> Enum.sort_by(& &1.total_cents)
  end
end
```
