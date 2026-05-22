# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `ShippingRateCalculator` module, top-level directive
- **Affected function(s):** `rate/2`, `cheapest_option/2`, `estimate_delivery/2`
- **Short explanation:** `ShippingRateCalculator` calls `use CarrierHelpers` to access weight-conversion and zone-lookup utilities. The `__using__/1` macro of `CarrierHelpers` silently injects an `import` of `WeightConverter` into the caller, making `to_lbs/2`, `to_kg/2`, and `within_limit?/3` available without any visible import statement in `ShippingRateCalculator`. Replacing `use CarrierHelpers` with `import CarrierHelpers` would make every dependency explicit and readable.

---

```elixir
defmodule WeightConverter do
  @factors %{kg: 2.20462, g: 0.00220462, oz: 0.0625, lb: 1.0}

  def to_lbs(amount, unit) do
    Float.round(amount * Map.get(@factors, unit, 1.0), 4)
  end

  def to_kg(amount, :lb), do: Float.round(amount / 2.20462, 4)
  def to_kg(amount, :g),  do: Float.round(amount / 1000.0, 4)
  def to_kg(amount, :kg), do: amount * 1.0
  def to_kg(amount, :oz), do: Float.round(amount * 0.0283495, 4)

  def within_limit?(amount, unit, max_lbs) do
    to_lbs(amount, unit) <= max_lbs
  end

  def billable_weight(actual_lbs, dims_cm) do
    {l, w, h} = dims_cm
    dim_weight = l * w * h / 5_000.0 * 2.20462
    max(actual_lbs, dim_weight)
  end
end

defmodule CarrierHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import WeightConverter`
      # VALIDATION: into ShippingRateCalculator. to_lbs/2, to_kg/2, within_limit?/3,
      # VALIDATION: and billable_weight/2 appear in ShippingRateCalculator without any
      # VALIDATION: explicit import declaration. A reader cannot know these come from
      # VALIDATION: WeightConverter without inspecting CarrierHelpers internally.
      # VALIDATION: A plain `import CarrierHelpers` would prevent this hidden propagation.
      import WeightConverter
      # VALIDATION: SMELL END

      @zones %{
        "US" => 1, "CA" => 2, "MX" => 3,
        "GB" => 4, "DE" => 4, "FR" => 4,
        "JP" => 6, "AU" => 7, "BR" => 5
      }

      def zone_for(destination_country) do
        Map.get(@zones, destination_country, 8)
      end

      def surcharge_for(:fuel),     do: 0.085
      def surcharge_for(:remote),   do: 4.50
      def surcharge_for(:oversize), do: 12.00
      def surcharge_for(_),         do: 0.0

      def apply_surcharges(base, surcharges) do
        Enum.reduce(surcharges, base, fn type, acc ->
          s = surcharge_for(type)
          if s > 1, do: acc + s, else: acc * (1 + s)
        end)
      end
    end
  end
end

defmodule ShippingRateCalculator do
  use CarrierHelpers

  @carriers %{
    fedex: %{
      base_rate:   [3.20, 4.10, 5.50, 7.30, 9.20, 14.00, 19.50, 28.00],
      per_lb:      [0.35, 0.42, 0.58, 0.75, 0.95, 1.30, 1.65, 2.10],
      max_weight:  150
    },
    ups: %{
      base_rate:   [3.00, 3.90, 5.20, 7.00, 9.00, 13.50, 18.00, 26.00],
      per_lb:      [0.33, 0.40, 0.55, 0.72, 0.90, 1.25, 1.60, 2.05],
      max_weight:  150
    },
    usps: %{
      base_rate:   [4.50, 5.50, 7.50, 10.00, 14.00, nil, nil, nil],
      per_lb:      [0.25, 0.30, 0.40, 0.55,  0.70,  nil, nil, nil],
      max_weight:  70
    }
  }

  def rate(shipment, carrier) do
    config = Map.fetch!(@carriers, carrier)
    lbs    = to_lbs(shipment.weight, shipment.weight_unit)
    bill   = billable_weight(lbs, shipment.dimensions || {10, 10, 10})
    zone   = zone_for(shipment.destination_country)
    idx    = zone - 1

    unless within_limit?(shipment.weight, shipment.weight_unit, config.max_weight) do
      {:error, "Shipment exceeds carrier weight limit"}
    else
      base    = Enum.at(config.base_rate, idx)
      per_lb  = Enum.at(config.per_lb, idx)

      if is_nil(base) do
        {:error, "Carrier does not serve zone #{zone}"}
      else
        raw   = base + per_lb * bill
        total = apply_surcharges(raw, shipment.surcharges || [:fuel])
        {:ok, %{carrier: carrier, zone: zone, lbs: bill, base: raw, total: Float.round(total, 2)}}
      end
    end
  end

  def cheapest_option(shipment, carriers \\ [:fedex, :ups, :usps]) do
    carriers
    |> Enum.map(&{&1, rate(shipment, &1)})
    |> Enum.filter(fn {_c, r} -> match?({:ok, _}, r) end)
    |> Enum.min_by(fn {_c, {:ok, r}} -> r.total end, fn -> {:error, :no_carriers_available} end)
  end

  def estimate_delivery(shipment, carrier) do
    zone  = zone_for(shipment.destination_country)
    lbs   = to_lbs(shipment.weight, shipment.weight_unit)

    days =
      case {carrier, zone} do
        {:fedex, z} when z <= 2 -> 1
        {:fedex, z} when z <= 4 -> 2
        {:fedex, _}             -> 3
        {:ups,   z} when z <= 2 -> 2
        {:ups,   _}             -> 3
        {:usps,  z} when z <= 3 -> 3
        {:usps,  _}             -> 7
      end

    extra = if lbs > 70, do: 1, else: 0
    {:ok, days + extra}
  end
end
```
