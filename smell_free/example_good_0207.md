# File: `example_good_207.md`

```elixir
defmodule Reports.FacetAggregator do
  @moduledoc """
  Computes faceted aggregations over a list of record maps.

  A facet is a breakdown of record counts (and optionally numeric sums)
  by the distinct values of a named field. The aggregator is stateless
  and side-effect free; it operates on in-memory data so it can be used
  in reporting pipelines that fetch records from any source.
  """

  @type record :: map()
  @type field :: atom() | String.t()

  @type facet_value :: %{
          value: term(),
          count: non_neg_integer(),
          sum: number() | nil
        }

  @type facet :: %{
          field: field(),
          values: [facet_value()],
          total_count: non_neg_integer()
        }

  @type facet_spec :: %{
          required(:field) => field(),
          optional(:sum_field) => field(),
          optional(:limit) => pos_integer(),
          optional(:sort_by) => :count | :value | :sum
        }

  @doc """
  Computes one or more facets from `records` according to `specs`.

  Returns a list of facet results in the same order as the input specs.
  """
  @spec aggregate([record()], [facet_spec()]) :: [facet()]
  def aggregate(records, specs) when is_list(records) and is_list(specs) do
    Enum.map(specs, &compute_facet(records, &1))
  end

  @doc """
  Computes a single facet for `field` across all records.

  The optional `:sum_field` accumulates a numeric sum per distinct value.
  The optional `:limit` caps the number of returned value buckets.
  The optional `:sort_by` controls bucket ordering (default: `:count` descending).
  """
  @spec facet([record()], facet_spec()) :: facet()
  def facet(records, spec) when is_list(records) and is_map(spec) do
    compute_facet(records, spec)
  end

  defp compute_facet(records, spec) do
    field = spec.field
    sum_field = Map.get(spec, :sum_field)
    limit = Map.get(spec, :limit)
    sort_by = Map.get(spec, :sort_by, :count)

    buckets = build_buckets(records, field, sum_field)
    sorted = sort_buckets(buckets, sort_by, sum_field)
    limited = apply_limit(sorted, limit)

    %{
      field: field,
      values: limited,
      total_count: length(records)
    }
  end

  defp build_buckets(records, field, sum_field) do
    records
    |> Enum.group_by(&get_field_value(&1, field))
    |> Enum.map(fn {value, group} ->
      sum = if sum_field, do: sum_field_values(group, sum_field), else: nil
      %{value: value, count: length(group), sum: sum}
    end)
  end

  defp sort_buckets(buckets, :count, _sum_field) do
    Enum.sort_by(buckets, & &1.count, :desc)
  end

  defp sort_buckets(buckets, :value, _sum_field) do
    Enum.sort_by(buckets, & &1.value)
  end

  defp sort_buckets(buckets, :sum, _sum_field) do
    Enum.sort_by(buckets, &(&1.sum || 0), :desc)
  end

  defp sort_buckets(buckets, _unknown, _sum_field), do: buckets

  defp apply_limit(buckets, nil), do: buckets
  defp apply_limit(buckets, limit) when is_integer(limit) and limit > 0 do
    Enum.take(buckets, limit)
  end

  defp get_field_value(record, field) when is_atom(field) do
    Map.get(record, field) || Map.get(record, Atom.to_string(field))
  end

  defp get_field_value(record, field) when is_binary(field) do
    Map.get(record, field) || Map.get(record, String.to_existing_atom(field))
  rescue
    ArgumentError -> Map.get(record, field)
  end

  defp sum_field_values(records, sum_field) do
    records
    |> Enum.map(&get_field_value(&1, sum_field))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  @doc """
  Merges two lists of facet values for the same field, combining counts
  and sums for shared values.

  Useful when aggregating over sharded datasets.
  """
  @spec merge_facet_values([facet_value()], [facet_value()]) :: [facet_value()]
  def merge_facet_values(left, right) when is_list(left) and is_list(right) do
    (left ++ right)
    |> Enum.group_by(& &1.value)
    |> Enum.map(fn {value, entries} ->
      %{
        value: value,
        count: Enum.sum(Enum.map(entries, & &1.count)),
        sum: merge_sums(entries)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp merge_sums(entries) do
    sums = Enum.map(entries, & &1.sum)
    if Enum.all?(sums, &is_nil/1), do: nil, else: Enum.sum(Enum.filter(sums, &is_number/1))
  end
end
```
