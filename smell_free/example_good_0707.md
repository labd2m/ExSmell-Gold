# File: `example_good_707.md`

```elixir
defmodule DataExport.ColumnProjector do
  @moduledoc """
  Projects a list of records onto a selected subset of columns,
  applying optional renames, value transformers, and a configurable
  column ordering.

  Projection specs are declarative maps that describe which source
  fields to include, how to label them in the output, and how to
  transform their values before export.
  """

  @type source_field :: atom() | String.t()
  @type output_header :: String.t()
  @type transform_fn :: (term() -> term())

  @type column_spec :: %{
          required(:from) => source_field(),
          required(:header) => output_header(),
          optional(:transform) => transform_fn(),
          optional(:default) => term()
        }

  @type projected_row :: %{String.t() => term()}

  @type projection_result :: %{
          headers: [output_header()],
          rows: [projected_row()]
        }

  @doc """
  Projects `records` onto the columns described by `specs`.

  Columns appear in the output in the order `specs` is given.
  Source fields missing from a record fall back to `:default` if
  specified, or `nil` otherwise.

  Returns a `projection_result` with an ordered header list and
  a list of maps keyed by header string.
  """
  @spec project([map()], [column_spec()]) :: projection_result()
  def project(records, specs) when is_list(records) and is_list(specs) do
    headers = Enum.map(specs, & &1.header)
    rows = Enum.map(records, &project_record(&1, specs))
    %{headers: headers, rows: rows}
  end

  @doc """
  Projects a single record according to `specs`.
  """
  @spec project_record(map(), [column_spec()]) :: projected_row()
  def project_record(record, specs) when is_map(record) and is_list(specs) do
    Map.new(specs, fn spec ->
      raw = get_source_value(record, spec.from, Map.get(spec, :default))
      value = apply_transform(raw, Map.get(spec, :transform))
      {spec.header, value}
    end)
  end

  @doc """
  Converts a `projection_result` to a list of ordered value tuples,
  one per row, for use with CSV or spreadsheet writers that expect
  positional arrays rather than maps.
  """
  @spec to_rows_array(projection_result()) :: [[term()]]
  def to_rows_array(%{headers: headers, rows: rows}) do
    Enum.map(rows, fn row ->
      Enum.map(headers, &Map.get(row, &1))
    end)
  end

  @doc """
  Adds a computed column derived from multiple source fields.

  `derive_fn` receives the full source record and returns the cell value.
  """
  @spec add_derived(column_spec(), output_header(), (map() -> term())) :: column_spec()
  def add_derived(base_spec, derived_header, derive_fn)
      when is_binary(derived_header) and is_function(derive_fn, 1) do
    %{base_spec | header: derived_header, transform: fn _val -> derive_fn end}
  end

  @doc """
  Builds a projection spec from a simple `{source_field, header}` pair.
  """
  @spec from_pair(source_field(), output_header()) :: column_spec()
  def from_pair(from, header), do: %{from: from, header: header}

  @doc """
  Builds projection specs from a keyword list of `source: "Header"` pairs.
  """
  @spec from_keyword([{source_field(), output_header()}]) :: [column_spec()]
  def from_keyword(pairs) when is_list(pairs) do
    Enum.map(pairs, fn {from, header} -> from_pair(from, header) end)
  end

  @doc """
  Filters `specs` to only those whose source field is present in at
  least one of `records`, removing specs for fields that don't exist
  in the dataset.
  """
  @spec prune_empty([column_spec()], [map()]) :: [column_spec()]
  def prune_empty(specs, records) when is_list(specs) and is_list(records) do
    all_keys =
      records
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string_key/1)
      |> MapSet.new()

    Enum.filter(specs, fn spec ->
      key = to_string_key(spec.from)
      MapSet.member?(all_keys, key)
    end)
  end

  defp get_source_value(record, field, default) when is_atom(field) do
    Map.get(record, field) ||
      Map.get(record, Atom.to_string(field)) ||
      default
  end

  defp get_source_value(record, field, default) when is_binary(field) do
    Map.get(record, field) ||
      Map.get(record, String.to_existing_atom(field)) ||
      default
  rescue
    ArgumentError -> Map.get(record, field, default)
  end

  defp apply_transform(value, nil), do: value
  defp apply_transform(value, transform_fn) when is_function(transform_fn, 1) do
    transform_fn.(value)
  rescue
    _ -> value
  end

  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_string_key(key) when is_binary(key), do: key
end
```
