```elixir
defmodule Reporting.MapUtils do
  @moduledoc """
  Map transformation utilities used by the reporting layer to
  normalise nested metric structures into flat, column-friendly maps.
  """

  defmacro flatten_keys(nested_map, prefix) do
    quote do
      Enum.reduce(unquote(nested_map), %{}, fn {k, v}, acc ->
        full_key =
          if unquote(prefix) == "",
            do: Atom.to_string(k),
            else: "#{unquote(prefix)}.#{Atom.to_string(k)}"

        if is_map(v) do
          Map.merge(acc, Reporting.MapUtils.flatten_keys(v, full_key))
        else
          Map.put(acc, full_key, v)
        end
      end)
    end
  end

  @doc """
  Renames keys in a map according to a provided mapping.
  Keys not present in the mapping are preserved unchanged.
  """
  @spec rename_keys(map(), map()) :: map()
  def rename_keys(input_map, key_mapping) do
    Map.new(input_map, fn {k, v} ->
      new_key = Map.get(key_mapping, k, k)
      {new_key, v}
    end)
  end

  @doc """
  Filters a map to only include the specified keys.
  """
  @spec select_keys(map(), list()) :: map()
  def select_keys(input_map, keys) do
    Map.take(input_map, keys)
  end
end

defmodule Reporting.MetricExporter do
  @moduledoc """
  Exports aggregated metric records into flat tabular structures
  suitable for CSV export, Google Sheets upload, or BI tool ingestion.
  """

  require Reporting.MapUtils

  alias Reporting.MapUtils

  @doc """
  Flattens a list of nested metric maps into a list of flat row maps,
  ready for CSV column mapping.
  """
  @spec flatten_records(list(map())) :: list(map())
  def flatten_records(records) do
    Enum.map(records, fn record ->
      MapUtils.flatten_keys(record, "")
    end)
  end

  @doc """
  Derives the CSV headers from a list of flat row maps.
  Headers are sorted alphabetically for consistency.
  """
  @spec derive_headers(list(map())) :: list(String.t())
  def derive_headers([]), do: []

  def derive_headers(rows) do
    rows
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Serialises a list of flat row maps into a CSV string.
  """
  @spec to_csv(list(map())) :: String.t()
  def to_csv([]), do: ""

  def to_csv(rows) do
    flat_rows = flatten_records(rows)
    headers = derive_headers(flat_rows)
    header_line = Enum.join(headers, ",")

    data_lines =
      Enum.map_join(flat_rows, "\n", fn row ->
        Enum.map_join(headers, ",", fn header ->
          value = Map.get(row, header, "")
          escape_csv_value(value)
        end)
      end)

    "#{header_line}\n#{data_lines}"
  end

  @doc """
  Returns a summary of the schema inferred from a list of records.
  """
  @spec schema_summary(list(map())) :: map()
  def schema_summary(records) do
    flat_records = flatten_records(records)
    headers = derive_headers(flat_records)

    %{
      column_count: length(headers),
      row_count: length(flat_records),
      columns: headers
    }
  end

  defp escape_csv_value(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp escape_csv_value(value), do: to_string(value)
end
```
