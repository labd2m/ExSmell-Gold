# File: `example_good_423.md`

```elixir
defmodule Finance.TaxCalculator do
  @moduledoc """
  Computes sales tax obligations across multiple jurisdictions given
  a set of line items and a destination address.

  Tax rules are supplied as a declarative list of rate specifications,
  keeping this module decoupled from any database or external tax API.
  Callers fetch the applicable rules for a jurisdiction and pass them in.
  """

  @type amount_cents :: non_neg_integer()
  @type jurisdiction :: String.t()
  @type tax_category :: :standard | :reduced | :zero | :exempt

  @type line_item :: %{
          required(:sku) => String.t(),
          required(:amount_cents) => amount_cents(),
          required(:tax_category) => tax_category()
        }

  @type rate_spec :: %{
          required(:jurisdiction) => jurisdiction(),
          required(:category) => tax_category(),
          required(:rate_bps) => non_neg_integer()
        }

  @type tax_line :: %{
          jurisdiction: jurisdiction(),
          taxable_cents: amount_cents(),
          rate_bps: non_neg_integer(),
          tax_cents: amount_cents()
        }

  @type tax_result :: %{
          subtotal_cents: amount_cents(),
          tax_lines: [tax_line()],
          total_tax_cents: amount_cents(),
          total_cents: amount_cents()
        }

  @doc """
  Calculates the tax breakdown for `line_items` using `rate_specs`.

  A rate spec matches a line item when its `:jurisdiction` and
  `:category` both match the item's fields. Exempt items contribute
  zero tax regardless of any matching rate.

  Returns a `tax_result` with per-jurisdiction tax lines.
  """
  @spec calculate([line_item()], [rate_spec()]) :: tax_result()
  def calculate(line_items, rate_specs)
      when is_list(line_items) and is_list(rate_specs) do
    rate_map = index_rates(rate_specs)
    subtotal = Enum.sum(Enum.map(line_items, & &1.amount_cents))

    jurisdictions = rate_specs |> Enum.map(& &1.jurisdiction) |> Enum.uniq()

    tax_lines =
      Enum.flat_map(jurisdictions, fn jur ->
        taxable = taxable_for_jurisdiction(line_items, rate_map, jur)
        if taxable > 0, do: [build_tax_line(jur, taxable, rate_map, line_items)], else: []
      end)
      |> Enum.reject(&(&1.tax_cents == 0))

    total_tax = Enum.sum(Enum.map(tax_lines, & &1.tax_cents))

    %{
      subtotal_cents: subtotal,
      tax_lines: Enum.sort_by(tax_lines, & &1.jurisdiction),
      total_tax_cents: total_tax,
      total_cents: subtotal + total_tax
    }
  end

  @doc """
  Returns the effective rate in basis points for a given jurisdiction
  and tax category. Returns `0` when no matching spec exists.
  """
  @spec effective_rate_bps([rate_spec()], jurisdiction(), tax_category()) :: non_neg_integer()
  def effective_rate_bps(rate_specs, jurisdiction, category) do
    rate_specs
    |> Enum.find(fn s -> s.jurisdiction == jurisdiction and s.category == category end)
    |> case do
      nil -> 0
      spec -> spec.rate_bps
    end
  end

  @doc """
  Returns a summary of total tax collected per jurisdiction across
  multiple tax results (e.g. for a batch of orders).
  """
  @spec aggregate_by_jurisdiction([tax_result()]) :: %{jurisdiction() => amount_cents()}
  def aggregate_by_jurisdiction(results) when is_list(results) do
    results
    |> Enum.flat_map(& &1.tax_lines)
    |> Enum.group_by(& &1.jurisdiction)
    |> Map.new(fn {jur, lines} -> {jur, Enum.sum(Enum.map(lines, & &1.tax_cents))} end)
  end

  defp index_rates(rate_specs) do
    Map.new(rate_specs, fn spec -> {{spec.jurisdiction, spec.category}, spec.rate_bps} end)
  end

  defp taxable_for_jurisdiction(line_items, rate_map, jurisdiction) do
    Enum.reduce(line_items, 0, fn item, acc ->
      rate = Map.get(rate_map, {jurisdiction, item.tax_category}, 0)
      if item.tax_category == :exempt or rate == 0, do: acc, else: acc + item.amount_cents
    end)
  end

  defp build_tax_line(jurisdiction, taxable_cents, rate_map, line_items) do
    dominant_category =
      line_items
      |> Enum.reject(&(&1.tax_category == :exempt))
      |> Enum.max_by(& &1.amount_cents, fn -> nil end)
      |> case do
        nil -> :standard
        item -> item.tax_category
      end

    rate_bps = Map.get(rate_map, {jurisdiction, dominant_category}, 0)
    tax_cents = div(taxable_cents * rate_bps, 10_000)

    %{
      jurisdiction: jurisdiction,
      taxable_cents: taxable_cents,
      rate_bps: rate_bps,
      tax_cents: tax_cents
    }
  end
end
```
