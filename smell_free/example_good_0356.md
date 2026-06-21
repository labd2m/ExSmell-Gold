```elixir
defmodule Commerce.TaxCalculator do
  @moduledoc """
  Computes applicable taxes for a cart based on the buyer's jurisdiction,
  the product tax categories, and a configurable tax rule set. Rules are
  loaded from application configuration at call time so rates can be
  updated without redeployment. All arithmetic is integer-based to avoid
  floating-point rounding errors in money calculations.
  """

  @type tax_category :: :standard | :reduced | :exempt | :digital_services
  @type jurisdiction :: String.t()
  @type line_item :: %{
          subtotal_cents: non_neg_integer(),
          tax_category: tax_category()
        }
  @type tax_line :: %{
          name: String.t(),
          rate_bps: non_neg_integer(),
          amount_cents: non_neg_integer()
        }
  @type tax_result :: %{
          subtotal_cents: non_neg_integer(),
          tax_lines: [tax_line()],
          total_tax_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @doc """
  Calculates taxes for `line_items` in `jurisdiction`. Returns a breakdown
  of each applied tax line and the final totals.
  """
  @spec calculate([line_item()], jurisdiction()) :: tax_result()
  def calculate(line_items, jurisdiction)
      when is_list(line_items) and is_binary(jurisdiction) do
    subtotal = Enum.sum_by(line_items, & &1.subtotal_cents)
    rules = fetch_rules(jurisdiction)
    tax_lines = compute_tax_lines(line_items, rules)
    total_tax = Enum.sum_by(tax_lines, & &1.amount_cents)

    %{
      subtotal_cents: subtotal,
      tax_lines: tax_lines,
      total_tax_cents: total_tax,
      total_cents: subtotal + total_tax
    }
  end

  @doc "Returns the effective tax rate in basis points for a category in a jurisdiction."
  @spec effective_rate_bps(jurisdiction(), tax_category()) :: non_neg_integer()
  def effective_rate_bps(jurisdiction, category)
      when is_binary(jurisdiction) and is_atom(category) do
    rules = fetch_rules(jurisdiction)
    Map.get(rules, category, %{}) |> Map.get(:rate_bps, 0)
  end

  defp compute_tax_lines(line_items, rules) do
    line_items
    |> Enum.group_by(& &1.tax_category)
    |> Enum.flat_map(fn {category, items} ->
      case Map.get(rules, category) do
        nil -> []
        %{rate_bps: 0} -> []
        %{name: name, rate_bps: rate} ->
          category_subtotal = Enum.sum_by(items, & &1.subtotal_cents)
          amount = div(category_subtotal * rate, 10_000)
          [%{name: name, rate_bps: rate, amount_cents: amount}]
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp fetch_rules(jurisdiction) do
    :my_app
    |> Application.get_env(:tax_rules, %{})
    |> Map.get(jurisdiction, default_rules())
  end

  defp default_rules do
    %{
      standard: %{name: "Sales Tax", rate_bps: 0},
      reduced: %{name: "Reduced Tax", rate_bps: 0},
      exempt: %{name: "Exempt", rate_bps: 0},
      digital_services: %{name: "Digital Services Tax", rate_bps: 0}
    }
  end
end
```
