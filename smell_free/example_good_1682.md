```elixir
defmodule Reports.DynamicBuilder do
  @moduledoc """
  Constructs SQL-backed reports from a declarative specification describing
  dimensions, metrics, filters, and sort order. The query is built
  compositionally and executed against the configured Repo.
  """

  import Ecto.Query

  @type dimension :: %{field: atom(), alias: String.t()}
  @type metric :: %{aggregate: :sum | :count | :avg | :min | :max, field: atom(), alias: String.t()}
  @type filter :: %{field: atom(), op: :eq | :neq | :gt | :lt | :gte | :lte | :in, value: term()}
  @type sort :: %{field: String.t(), direction: :asc | :desc}

  @type report_spec :: %{
          source: module(),
          dimensions: [dimension()],
          metrics: [metric()],
          filters: [filter()],
          sort: [sort()],
          limit: pos_integer() | nil
        }

  @spec run(report_spec(), module()) :: {:ok, [map()]} | {:error, atom()}
  def run(spec, repo) when is_map(spec) do
    with :ok <- validate_spec(spec) do
      results =
        spec.source
        |> base_query()
        |> apply_filters(spec.filters)
        |> apply_group_by(spec.dimensions)
        |> apply_select(spec.dimensions, spec.metrics)
        |> apply_order(spec.sort)
        |> apply_limit(spec.limit)
        |> repo.all()

      {:ok, results}
    end
  rescue
    e in Ecto.QueryError -> {:error, {:query_error, Exception.message(e)}}
    _ -> {:error, :unexpected_error}
  end

  @spec base_query(module()) :: Ecto.Query.t()
  defp base_query(source), do: from(r in source)

  @spec apply_filters(Ecto.Query.t(), [filter()]) :: Ecto.Query.t()
  defp apply_filters(query, []), do: query

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_filter(q, filter)
    end)
  end

  @spec apply_filter(Ecto.Query.t(), filter()) :: Ecto.Query.t()
  defp apply_filter(query, %{field: field, op: :eq, value: value}) do
    from(r in query, where: field(r, ^field) == ^value)
  end

  defp apply_filter(query, %{field: field, op: :neq, value: value}) do
    from(r in query, where: field(r, ^field) != ^value)
  end

  defp apply_filter(query, %{field: field, op: :gt, value: value}) do
    from(r in query, where: field(r, ^field) > ^value)
  end

  defp apply_filter(query, %{field: field, op: :lt, value: value}) do
    from(r in query, where: field(r, ^field) < ^value)
  end

  defp apply_filter(query, %{field: field, op: :gte, value: value}) do
    from(r in query, where: field(r, ^field) >= ^value)
  end

  defp apply_filter(query, %{field: field, op: :lte, value: value}) do
    from(r in query, where: field(r, ^field) <= ^value)
  end

  defp apply_filter(query, %{field: field, op: :in, value: values}) when is_list(values) do
    from(r in query, where: field(r, ^field) in ^values)
  end

  @spec apply_group_by(Ecto.Query.t(), [dimension()]) :: Ecto.Query.t()
  defp apply_group_by(query, []), do: query

  defp apply_group_by(query, dimensions) do
    fields = Enum.map(dimensions, & &1.field)
    from(r in query, group_by: ^fields)
  end

  @spec apply_select(Ecto.Query.t(), [dimension()], [metric()]) :: Ecto.Query.t()
  defp apply_select(query, dimensions, metrics) do
    dim_select = Enum.map(dimensions, fn d -> {d.alias, d.field} end)
    metric_select = Enum.map(metrics, fn m -> {m.alias, m.aggregate, m.field} end)
    from(r in query, select: %{
      ^dim_select => fragment(""),
      ^metric_select => fragment("")
    })
    |> build_select(dimensions, metrics)
  end

  defp build_select(query, dimensions, metrics) do
    select_map =
      Enum.reduce(dimensions, %{}, fn d, acc ->
        Map.put(acc, d.alias, dynamic([r], field(r, ^d.field)))
      end)
      |> then(fn acc ->
        Enum.reduce(metrics, acc, fn m, inner_acc ->
          agg = build_aggregate(m)
          Map.put(inner_acc, m.alias, agg)
        end)
      end)

    from(r in query, select: ^select_map)
  end

  @spec build_aggregate(metric()) :: Macro.t()
  defp build_aggregate(%{aggregate: :count, field: field}), do: dynamic([r], count(field(r, ^field)))
  defp build_aggregate(%{aggregate: :sum, field: field}), do: dynamic([r], sum(field(r, ^field)))
  defp build_aggregate(%{aggregate: :avg, field: field}), do: dynamic([r], avg(field(r, ^field)))
  defp build_aggregate(%{aggregate: :min, field: field}), do: dynamic([r], min(field(r, ^field)))
  defp build_aggregate(%{aggregate: :max, field: field}), do: dynamic([r], max(field(r, ^field)))

  @spec apply_order(Ecto.Query.t(), [sort()]) :: Ecto.Query.t()
  defp apply_order(query, []), do: query

  defp apply_order(query, sorts) do
    Enum.reduce(sorts, query, fn %{field: field, direction: dir}, q ->
      field_atom = String.to_existing_atom(field)
      from(r in q, order_by: [{^dir, field(r, ^field_atom)}])
    end)
  rescue
    _ -> query
  end

  @spec apply_limit(Ecto.Query.t(), pos_integer() | nil) :: Ecto.Query.t()
  defp apply_limit(query, nil), do: query
  defp apply_limit(query, limit), do: from(r in query, limit: ^limit)

  @spec validate_spec(report_spec()) :: :ok | {:error, atom()}
  defp validate_spec(%{source: source}) when not is_atom(source), do: {:error, :invalid_source}
  defp validate_spec(%{dimensions: d, metrics: m}) when d == [] and m == [], do: {:error, :no_columns}
  defp validate_spec(_), do: :ok
end
```
