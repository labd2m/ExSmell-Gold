# File: `example_good_240.md`

```elixir
defmodule Reporting.PivotTable do
  @moduledoc """
  Builds pivot tables from flat record lists by grouping on row and column
  dimensions and aggregating a value field with a chosen function.

  All operations are pure; no I/O occurs. Feed it a list of maps from any
  source — database query results, CSV imports, API responses — and receive
  a structured grid suitable for serialisation or display.
  """

  @type field :: atom() | String.t()
  @type aggregator :: :sum | :count | :mean | :min | :max
  @type cell_value :: number() | nil

  @type pivot_result :: %{
          row_headers: [term()],
          col_headers: [term()],
          cells: %{{term(), term()} => cell_value()},
          row_totals: %{term() => cell_value()},
          col_totals: %{term() => cell_value()},
          grand_total: cell_value()
        }

  @doc """
  Builds a pivot table from `records`.

  Parameters:
  - `row_field` — field whose distinct values form the row axis
  - `col_field` — field whose distinct values form the column axis
  - `value_field` — numeric field to aggregate at each cell intersection
  - `aggregator` — one of `:sum`, `:count`, `:mean`, `:min`, `:max`

  Returns a `pivot_result` with sorted headers, cell values, and totals.
  """
  @spec build([map()], field(), field(), field(), aggregator()) :: pivot_result()
  def build(records, row_field, col_field, value_field, aggregator \\ :sum)
      when is_list(records) do
    grouped = group_records(records, row_field, col_field)

    row_headers = grouped |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    col_headers = grouped |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    cells = build_cells(grouped, value_field, aggregator)
    row_totals = build_row_totals(cells, row_headers, col_headers)
    col_totals = build_col_totals(cells, row_headers, col_headers)
    grand_total = aggregate(Map.values(cells) |> Enum.reject(&is_nil/1), aggregator)

    %{
      row_headers: row_headers,
      col_headers: col_headers,
      cells: cells,
      row_totals: row_totals,
      col_totals: col_totals,
      grand_total: grand_total
    }
  end

  @doc """
  Renders a pivot result as a list of row maps, where each map contains
  the row key plus one key per column header plus a `:total` key.

  Suitable for JSON serialisation or CSV export.
  """
  @spec to_rows(pivot_result(), field()) :: [map()]
  def to_rows(%{row_headers: rows, col_headers: cols, cells: cells, row_totals: totals}, row_key) do
    Enum.map(rows, fn row ->
      col_values = Map.new(cols, fn col -> {col, Map.get(cells, {row, col})} end)
      Map.merge(%{row_key => row, :total => Map.get(totals, row)}, col_values)
    end)
  end

  defp group_records(records, row_field, col_field) do
    Enum.group_by(records, fn record ->
      {get_field(record, row_field), get_field(record, col_field)}
    end)
  end

  defp build_cells(grouped, value_field, aggregator) do
    Map.new(grouped, fn {key, group} ->
      values = group |> Enum.map(&get_field(&1, value_field)) |> Enum.filter(&is_number/1)
      {key, aggregate(values, aggregator)}
    end)
  end

  defp build_row_totals(cells, row_headers, col_headers) do
    Map.new(row_headers, fn row ->
      values =
        col_headers
        |> Enum.map(&Map.get(cells, {row, &1}))
        |> Enum.reject(&is_nil/1)

      {row, aggregate(values, :sum)}
    end)
  end

  defp build_col_totals(cells, row_headers, col_headers) do
    Map.new(col_headers, fn col ->
      values =
        row_headers
        |> Enum.map(&Map.get(cells, {&1, col}))
        |> Enum.reject(&is_nil/1)

      {col, aggregate(values, :sum)}
    end)
  end

  defp aggregate([], _aggregator), do: nil
  defp aggregate(values, :sum), do: Enum.sum(values)
  defp aggregate(values, :count), do: length(values)
  defp aggregate(values, :mean), do: Enum.sum(values) / length(values)
  defp aggregate(values, :min), do: Enum.min(values)
  defp aggregate(values, :max), do: Enum.max(values)

  defp get_field(record, field) when is_atom(field) do
    Map.get(record, field) || Map.get(record, Atom.to_string(field))
  end

  defp get_field(record, field) when is_binary(field) do
    Map.get(record, field) || Map.get(record, String.to_existing_atom(field))
  rescue
    ArgumentError -> Map.get(record, field)
  end
end
```
