# File: `example_good_616.md`

```elixir
defmodule Reporting.CrossTabulation do
  @moduledoc """
  Builds cross-tabulation (contingency) tables from a list of records,
  showing the joint distribution of two categorical variables.

  Cell values can be raw counts, row percentages, column percentages,
  or total percentages. Chi-squared statistics are available to test
  for independence between the two variables.
  """

  @type record :: map()
  @type field :: atom() | String.t()
  @type cell_mode :: :count | :row_pct | :col_pct | :total_pct

  @type cross_tab :: %{
          row_field: field(),
          col_field: field(),
          row_values: [term()],
          col_values: [term()],
          cells: %{{term(), term()} => number()},
          row_totals: %{term() => non_neg_integer()},
          col_totals: %{term() => non_neg_integer()},
          grand_total: non_neg_integer()
        }

  @doc """
  Builds a cross-tabulation of `row_field` by `col_field` from `records`.

  `mode` controls how cell values are expressed:
  - `:count` — raw counts (default)
  - `:row_pct` — percentage within each row
  - `:col_pct` — percentage within each column
  - `:total_pct` — percentage of grand total

  Returns a `cross_tab` with sorted row and column values.
  """
  @spec build([record()], field(), field(), cell_mode()) :: cross_tab()
  def build(records, row_field, col_field, mode \\ :count)
      when is_list(records) do
    counts = tally(records, row_field, col_field)
    row_values = counts |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    col_values = counts |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    row_totals = compute_row_totals(counts, row_values, col_values)
    col_totals = compute_col_totals(counts, row_values, col_values)
    grand_total = Enum.sum(Map.values(row_totals))

    cells = compute_cells(counts, row_values, col_values, row_totals, col_totals, grand_total, mode)

    %{
      row_field: row_field,
      col_field: col_field,
      row_values: row_values,
      col_values: col_values,
      cells: cells,
      row_totals: row_totals,
      col_totals: col_totals,
      grand_total: grand_total
    }
  end

  @doc """
  Computes the Pearson chi-squared statistic for a cross-tabulation.

  Returns `{chi_squared, degrees_of_freedom}`. A higher value suggests
  the variables are not independent.
  """
  @spec chi_squared(cross_tab()) :: {float(), non_neg_integer()}
  def chi_squared(%{cells: _, row_values: rows, col_values: cols,
                    row_totals: row_totals, col_totals: col_totals, grand_total: n}) do
    counts = build_count_map(rows, cols, row_totals, col_totals, n)

    chi_sq =
      Enum.reduce(counts, 0.0, fn {{row, col}, {observed, expected}}, acc ->
        if expected > 0 do
          acc + :math.pow(observed - expected, 2) / expected
        else
          acc
        end
      end)

    df = (length(rows) - 1) * (length(cols) - 1)
    {Float.round(chi_sq, 4), df}
  end

  @doc """
  Renders a cross-tabulation as a list of row maps for serialisation.
  """
  @spec to_rows(cross_tab()) :: [map()]
  def to_rows(%{row_values: rows, col_values: cols, cells: cells, row_totals: row_totals, row_field: rf}) do
    Enum.map(rows, fn row ->
      col_entries = Map.new(cols, fn col -> {col, Map.get(cells, {row, col}, 0)} end)
      Map.merge(%{rf => row, :row_total => Map.get(row_totals, row, 0)}, col_entries)
    end)
  end

  defp tally(records, row_field, col_field) do
    Enum.reduce(records, %{}, fn rec, acc ->
      row_val = get_field(rec, row_field)
      col_val = get_field(rec, col_field)

      if not is_nil(row_val) and not is_nil(col_val) do
        Map.update(acc, {row_val, col_val}, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp compute_row_totals(counts, row_values, col_values) do
    Map.new(row_values, fn row ->
      total = Enum.sum(Enum.map(col_values, &Map.get(counts, {row, &1}, 0)))
      {row, total}
    end)
  end

  defp compute_col_totals(counts, row_values, col_values) do
    Map.new(col_values, fn col ->
      total = Enum.sum(Enum.map(row_values, &Map.get(counts, {&1, col}, 0)))
      {col, total}
    end)
  end

  defp compute_cells(counts, rows, cols, row_totals, col_totals, grand_total, mode) do
    for row <- rows, col <- cols, into: %{} do
      count = Map.get(counts, {row, col}, 0)

      value =
        case mode do
          :count -> count
          :row_pct -> pct(count, Map.get(row_totals, row, 0))
          :col_pct -> pct(count, Map.get(col_totals, col, 0))
          :total_pct -> pct(count, grand_total)
        end

      {{row, col}, value}
    end
  end

  defp build_count_map(rows, cols, row_totals, col_totals, n) do
    for row <- rows, col <- cols, into: %{} do
      observed = Map.get(row_totals, row, 0) * Map.get(col_totals, col, 0)
      expected = if n > 0, do: observed / n, else: 0.0
      {{row, col}, {Map.get(row_totals, row, 0), expected}}
    end
  end

  defp pct(_count, 0), do: 0.0
  defp pct(count, total), do: Float.round(count / total * 100.0, 2)

  defp get_field(record, field) when is_atom(field) do
    Map.get(record, field) || Map.get(record, Atom.to_string(field))
  end

  defp get_field(record, field) when is_binary(field) do
    Map.get(record, field)
  end
end
```
