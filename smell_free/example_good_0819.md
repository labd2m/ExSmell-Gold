# File: `example_good_819.md`

```elixir
defmodule Reports.WaterfallBuilder do
  @moduledoc """
  Builds waterfall chart data structures from a sequence of labelled
  value deltas, computing running totals and identifying whether each
  bar represents a positive contribution, negative contribution, or
  a subtotal/total checkpoint.

  Waterfall charts are commonly used in financial reporting to show
  how individual factors contribute to a net result.
  """

  @type label :: String.t()
  @type amount :: number()

  @type bar_kind :: :positive | :negative | :subtotal | :total

  @type bar :: %{
          label: label(),
          amount: amount(),
          running_total: amount(),
          base: amount(),
          kind: bar_kind()
        }

  @type waterfall :: %{
          bars: [bar()],
          opening_value: amount(),
          closing_value: amount(),
          net_change: amount()
        }

  @type input_bar ::
          {:delta, label(), amount()}
          | {:subtotal, label()}
          | {:total, label()}

  @doc """
  Builds a waterfall chart from `opening_value` and a list of
  `input_bars`.

  Input bar types:
  - `{:delta, label, amount}` — a contributing change (positive or negative)
  - `{:subtotal, label}` — inserts a running total bar without advancing it
  - `{:total, label}` — inserts the final total bar

  Returns a `waterfall` with fully computed bar positions and values.
  """
  @spec build(amount(), [input_bar()]) :: waterfall()
  def build(opening_value, input_bars)
      when is_number(opening_value) and is_list(input_bars) do
    {bars, running_total} =
      Enum.reduce(input_bars, {[], opening_value}, fn input, {acc, total} ->
        bar = build_bar(input, total)
        new_total = updated_total(input, total)
        {[bar | acc], new_total}
      end)

    ordered = Enum.reverse(bars)
    closing = List.last(ordered) |> then(fn b -> if b, do: b.running_total, else: opening_value end)

    %{
      bars: ordered,
      opening_value: opening_value,
      closing_value: closing,
      net_change: closing - opening_value
    }
  end

  @doc """
  Returns only bars of the given `kind` from a waterfall.
  """
  @spec filter_kind(waterfall(), bar_kind()) :: [bar()]
  def filter_kind(%{bars: bars}, kind) when is_atom(kind) do
    Enum.filter(bars, &(&1.kind == kind))
  end

  @doc """
  Formats a waterfall bar as a `{label, base, amount}` tuple suitable
  for direct consumption by charting libraries that expect positional data.
  """
  @spec to_chart_tuples(waterfall()) :: [{label(), amount(), amount()}]
  def to_chart_tuples(%{bars: bars}) do
    Enum.map(bars, fn bar -> {bar.label, bar.base, bar.amount} end)
  end

  @doc """
  Appends an opening bar representing the starting value.
  """
  @spec with_opening_bar(waterfall(), label()) :: waterfall()
  def with_opening_bar(%{bars: bars, opening_value: opening} = wf, label) do
    opening_bar = %{
      label: label,
      amount: opening,
      running_total: opening,
      base: 0,
      kind: :total
    }

    %{wf | bars: [opening_bar | bars]}
  end

  defp build_bar({:delta, label, amount}, running_total) do
    kind = if amount >= 0, do: :positive, else: :negative
    base = if amount >= 0, do: running_total, else: running_total + amount

    %{
      label: label,
      amount: abs(amount),
      running_total: running_total + amount,
      base: base,
      kind: kind
    }
  end

  defp build_bar({:subtotal, label}, running_total) do
    %{
      label: label,
      amount: running_total,
      running_total: running_total,
      base: 0,
      kind: :subtotal
    }
  end

  defp build_bar({:total, label}, running_total) do
    %{
      label: label,
      amount: running_total,
      running_total: running_total,
      base: 0,
      kind: :total
    }
  end

  defp updated_total({:delta, _label, amount}, total), do: total + amount
  defp updated_total({:subtotal, _label}, total), do: total
  defp updated_total({:total, _label}, total), do: total
end
```
