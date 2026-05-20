## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `calculate_shipping_cost/1`, all three clauses
- **Affected function(s)**: `calculate_shipping_cost/1`
- **Short explanation**: Every clause of `calculate_shipping_cost/1` destructures `origin`, `destination`, `dimensions`, `declared_value`, and `customer_tier` from `%Shipment{}` for body-only use. Guards only inspect `carrier` and `weight_kg`. The repeated full extraction across three clauses forces readers to look at the entire clause head to figure out which fields control dispatch, which is the core of this smell.

```elixir
defmodule Logistics.ShippingCalculator do
  alias Logistics.{Shipment, CarrierRate, ZoneMatrix, InsurancePolicy, AuditTrail}
  require Logger

  @moduledoc """
  Calculates shipping costs for domestic and international shipments.
  Rates vary by carrier, weight, dimensions, and customer tier.
  """

  @fuel_surcharge_rate 0.085
  @oversize_threshold_cm3 50_000

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `origin`, `destination`, `dimensions`, `declared_value`,
  # VALIDATION: and `customer_tier` are extracted in every clause solely for body use. Only
  # VALIDATION: `carrier` and `weight_kg` are referenced in guard expressions. Having five
  # VALIDATION: body-only bindings alongside two guard-relevant ones in each of three clause
  # VALIDATION: heads makes it hard to understand what actually governs clause selection.
  def calculate_shipping_cost(%Shipment{
        id: id,
        carrier: carrier,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        customer_tier: customer_tier
      })
      when carrier == :express and weight_kg <= 30 do
    Logger.debug("Express rate calculation for shipment #{id}")
    zone = ZoneMatrix.lookup(origin, destination)
    base_rate = CarrierRate.express_rate(zone, weight_kg)
    volume_cm3 = dimensions.length * dimensions.width * dimensions.height
    oversize_surcharge = if volume_cm3 > @oversize_threshold_cm3, do: base_rate * 0.15, else: 0.0
    fuel_surcharge = base_rate * @fuel_surcharge_rate
    insurance = InsurancePolicy.premium(declared_value, :express)
    discount = tier_discount(customer_tier)
    subtotal = (base_rate + oversize_surcharge + fuel_surcharge + insurance) * (1 - discount)

    AuditTrail.log_rate_calculation(id, :express, %{
      zone: zone,
      base_rate: base_rate,
      fuel_surcharge: fuel_surcharge,
      insurance: insurance,
      discount: discount
    })

    {:ok, Float.round(subtotal, 2)}
  end

  def calculate_shipping_cost(%Shipment{
        id: id,
        carrier: carrier,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        customer_tier: customer_tier
      })
      when carrier == :standard and weight_kg <= 70 do
    Logger.debug("Standard rate calculation for shipment #{id}")
    zone = ZoneMatrix.lookup(origin, destination)
    base_rate = CarrierRate.standard_rate(zone, weight_kg)
    volume_cm3 = dimensions.length * dimensions.width * dimensions.height
    oversize_surcharge = if volume_cm3 > @oversize_threshold_cm3, do: base_rate * 0.10, else: 0.0
    fuel_surcharge = base_rate * @fuel_surcharge_rate
    insurance = InsurancePolicy.premium(declared_value, :standard)
    discount = tier_discount(customer_tier)
    subtotal = (base_rate + oversize_surcharge + fuel_surcharge + insurance) * (1 - discount)

    AuditTrail.log_rate_calculation(id, :standard, %{
      zone: zone,
      base_rate: base_rate,
      fuel_surcharge: fuel_surcharge,
      insurance: insurance,
      discount: discount
    })

    {:ok, Float.round(subtotal, 2)}
  end

  def calculate_shipping_cost(%Shipment{
        id: id,
        carrier: carrier,
        weight_kg: weight_kg,
        origin: origin,
        destination: destination,
        dimensions: dimensions,
        declared_value: declared_value,
        customer_tier: customer_tier
      })
      when carrier == :freight and weight_kg > 70 do
    Logger.debug("Freight rate calculation for shipment #{id}")
    zone = ZoneMatrix.lookup(origin, destination)
    base_rate = CarrierRate.freight_rate(zone, weight_kg)
    volume_cm3 = dimensions.length * dimensions.width * dimensions.height
    oversize_surcharge = if volume_cm3 > @oversize_threshold_cm3 * 3, do: base_rate * 0.20, else: 0.0
    fuel_surcharge = base_rate * (@fuel_surcharge_rate + 0.02)
    insurance = InsurancePolicy.premium(declared_value, :freight)
    discount = tier_discount(customer_tier)
    subtotal = (base_rate + oversize_surcharge + fuel_surcharge + insurance) * (1 - discount)

    AuditTrail.log_rate_calculation(id, :freight, %{
      zone: zone,
      base_rate: base_rate,
      fuel_surcharge: fuel_surcharge,
      insurance: insurance,
      discount: discount
    })

    {:ok, Float.round(subtotal, 2)}
  end
  # VALIDATION: SMELL END

  defp tier_discount(:platinum), do: 0.15
  defp tier_discount(:gold), do: 0.10
  defp tier_discount(:silver), do: 0.05
  defp tier_discount(_), do: 0.0
end
```
