```elixir
defmodule PrecisionMath do
  def ceil_at(value, decimals) do
    factor = :math.pow(10, decimals)
    :math.ceil(value * factor) / factor
  end

  def floor_at(value, decimals) do
    factor = :math.pow(10, decimals)
    :math.floor(value * factor) / factor
  end

  def banker_round(value, decimals \\ 2) do
    factor = :math.pow(10, decimals)
    scaled = value * factor
    base   = trunc(scaled)
    frac   = scaled - base

    rounded =
      cond do
        frac > 0.5  -> base + 1
        frac < 0.5  -> base
        rem(base, 2) == 0 -> base
        true        -> base + 1
      end

    rounded / factor
  end

  def truncate_at(value, decimals) do
    factor = :math.pow(10, decimals)
    trunc(value * factor) / factor
  end
end

defmodule RoundingHelpers do
  defmacro __using__(_opts) do
    quote do
      import PrecisionMath

      def apply_rate(amount, rate), do: amount * rate

      def compound_rates(rates) do
        Enum.reduce(rates, 1.0, fn r, acc -> acc * (1 + r) end) - 1.0
      end

      def split_combined_rate(combined, primary_rate) do
        secondary = combined - primary_rate - combined * primary_rate
        %{primary: primary_rate, secondary: banker_round(secondary, 4)}
      end
    end
  end
end

defmodule TaxCalculator do
  use RoundingHelpers

  @jurisdictions %{
    "US-CA" => %{state: 0.0725, county: 0.01,  city: 0.0},
    "US-NY" => %{state: 0.04,   county: 0.045, city: 0.04875},
    "US-TX" => %{state: 0.0625, county: 0.02,  city: 0.0},
    "EU-DE" => %{state: 0.19,   county: 0.0,   city: 0.0},
    "EU-FR" => %{state: 0.20,   county: 0.0,   city: 0.0}
  }

  def compute(amount, jurisdiction) do
    rates = Map.get(@jurisdictions, jurisdiction, %{state: 0.0, county: 0.0, city: 0.0})

    state_tax  = banker_round(apply_rate(amount, rates.state),  2)
    county_tax = banker_round(apply_rate(amount, rates.county), 2)
    city_tax   = banker_round(apply_rate(amount, rates.city),   2)
    total_tax  = banker_round(state_tax + county_tax + city_tax, 2)

    %{
      amount:       amount,
      jurisdiction: jurisdiction,
      state_tax:    state_tax,
      county_tax:   county_tax,
      city_tax:     city_tax,
      total_tax:    total_tax,
      total:        banker_round(amount + total_tax, 2)
    }
  end

  def breakdown(amount, jurisdiction) do
    rates = Map.get(@jurisdictions, jurisdiction, %{state: 0.0, county: 0.0, city: 0.0})

    combined = compound_rates([rates.state, rates.county, rates.city])

    %{
      gross:           amount,
      combined_rate:   truncate_at(combined * 100, 4),
      net_of_tax:      floor_at(amount / (1 + combined), 2),
      tax_on_top:      ceil_at(apply_rate(amount, combined), 2),
      breakdown:       compute(amount, jurisdiction)
    }
  end

  def effective_rate(amount, jurisdiction) do
    result = compute(amount, jurisdiction)
    if amount > 0,
      do: banker_round(result.total_tax / amount * 100, 4),
      else: 0.0
  end

  def bulk_compute(line_items, jurisdiction) do
    Enum.map(line_items, fn item ->
      taxed = compute(item.amount, jurisdiction)
      Map.merge(item, %{tax_details: taxed})
    end)
  end

  def supported_jurisdictions, do: Map.keys(@jurisdictions)
end
```
