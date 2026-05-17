# Annotated Example 11

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Reporting.FieldDescriptorParser.parse_field/1`
- **Affected function(s):** `parse_field/1`
- **Short explanation:** The function splits a field descriptor string on `"."` and extracts
  dataset, table, and column names by index using `Enum.at/2`. If a dataset or table name
  contains a dot (which is valid in many warehouse naming conventions, e.g.
  `"analytics.v2.orders.revenue"`), the indices shift and the function silently assigns the
  wrong segments to each field — returning a plausible-looking struct with incorrect values
  rather than raising an error.

---

```elixir
defmodule Reporting.FieldDescriptorParser do
  @moduledoc """
  Parses field descriptor strings used in the report-builder query DSL.

  Field descriptors identify columns in the data warehouse using a
  three-part dot-separated path:

    "<dataset>.<table>.<column>"

  Optionally, a column may carry an aggregation suffix separated by ":":

    "<dataset>.<table>.<column>:<aggregation>"

  Examples:
    "billing.invoices.total_amount"
    "billing.invoices.total_amount:sum"
    "logistics.shipments.dispatch_date:max"
    "auth.sessions.user_id:count_distinct"
  """

  @valid_aggregations ~w(sum avg min max count count_distinct first last)

  defstruct [:dataset, :table, :column, :aggregation, :alias]

  @doc """
  Parses a single field descriptor string into a `%FieldDescriptorParser{}` struct.

  Returns `{:ok, struct}` on success or `{:error, reason}` if the aggregation
  suffix is not recognised.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `parse_field/1` splits on "." and uses
  # VALIDATION: `Enum.at/2` at fixed positions (0, 1, 2) to extract dataset, table,
  # VALIDATION: and column. Warehouse naming conventions commonly allow versioned dataset
  # VALIDATION: names like "billing.v2" (two dot-separated tokens), so a descriptor such
  # VALIDATION: as "billing.v2.invoices.total_amount:sum" yields four tokens. The function
  # VALIDATION: silently assigns "billing" → dataset, "v2" → table, "invoices" → column,
  # VALIDATION: and ignores "total_amount:sum" entirely. No error is raised; the returned
  # VALIDATION: struct looks legitimate but refers to the wrong field.
  def parse_field(raw) when is_binary(raw) do
    {path_part, agg_part} = split_aggregation(raw)

    segments = String.split(path_part, ".")

    dataset = Enum.at(segments, 0)
    table   = Enum.at(segments, 1)
    column  = Enum.at(segments, 2)

    case validate_aggregation(agg_part) do
      :ok ->
        {:ok, %__MODULE__{
          dataset:     dataset,
          table:       table,
          column:      column,
          aggregation: agg_part,
          alias:       build_alias(dataset, table, column, agg_part)
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Parses a list of field descriptors, partitioning results into `:ok` and `:error`.
  """
  def parse_many(raw_fields) when is_list(raw_fields) do
    Enum.reduce(raw_fields, %{ok: [], error: []}, fn raw, acc ->
      case parse_field(raw) do
        {:ok, field}     -> %{acc | ok:    [field | acc.ok]}
        {:error, reason} -> %{acc | error: [{raw, reason} | acc.error]}
      end
    end)
    |> then(fn acc -> %{acc | ok: Enum.reverse(acc.ok), error: Enum.reverse(acc.error)} end)
  end

  @doc """
  Returns true when a parsed field struct has all required components populated.
  """
  def complete?(%__MODULE__{dataset: d, table: t, column: c})
      when is_binary(d) and is_binary(t) and is_binary(c),
      do: true

  def complete?(_), do: false

  @doc """
  Converts a field struct to the SQL column expression used in query generation.
  """
  def to_sql_expression(%__MODULE__{aggregation: nil} = field) do
    ~s("#{field.dataset}"."#{field.table}"."#{field.column}")
  end

  def to_sql_expression(%__MODULE__{aggregation: agg} = field) do
    col = ~s("#{field.dataset}"."#{field.table}"."#{field.column}")

    case agg do
      "count_distinct" -> "COUNT(DISTINCT #{col})"
      _                -> "#{String.upcase(agg)}(#{col})"
    end
  end

  @doc """
  Returns all valid aggregation function names supported by this parser.
  """
  def supported_aggregations, do: @valid_aggregations

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp split_aggregation(raw) do
    case String.split(raw, ":", parts: 2) do
      [path, agg] -> {path, agg}
      [path]      -> {path, nil}
    end
  end

  defp validate_aggregation(nil), do: :ok

  defp validate_aggregation(agg) when is_binary(agg) do
    if agg in @valid_aggregations do
      :ok
    else
      {:error, {:unsupported_aggregation, agg, @valid_aggregations}}
    end
  end

  defp build_alias(dataset, table, column, nil),  do: "#{dataset}_#{table}_#{column}"
  defp build_alias(dataset, table, column, agg),  do: "#{dataset}_#{table}_#{column}_#{agg}"
end
```
