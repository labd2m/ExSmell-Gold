```elixir
defmodule Search.QueryBuilder do
  @moduledoc """
  Constructs composable Elasticsearch-compatible query documents from
  a structured filter description. Each filter type maps to a dedicated
  clause builder, and clauses are combined into a boolean query.
  """

  @type range_bound :: %{gte: term()} | %{lte: term()} | %{gte: term(), lte: term()}

  @type filter ::
          {:term, field :: String.t(), value :: term()}
          | {:terms, field :: String.t(), values :: [term()]}
          | {:range, field :: String.t(), range_bound()}
          | {:exists, field :: String.t()}
          | {:prefix, field :: String.t(), prefix :: String.t()}
          | {:nested, path :: String.t(), [filter()]}

  @type query_opts :: [
          must: [filter()],
          should: [filter()],
          must_not: [filter()],
          minimum_should_match: pos_integer()
        ]

  @spec build(query_opts()) :: map()
  def build(opts \\ []) when is_list(opts) do
    must = opts |> Keyword.get(:must, []) |> Enum.map(&build_clause/1)
    should = opts |> Keyword.get(:should, []) |> Enum.map(&build_clause/1)
    must_not = opts |> Keyword.get(:must_not, []) |> Enum.map(&build_clause/1)
    min_should = Keyword.get(opts, :minimum_should_match, 1)

    bool =
      %{}
      |> put_if_present(:must, must)
      |> put_if_present(:should, should)
      |> put_if_present(:must_not, must_not)
      |> maybe_put_minimum_should_match(should, min_should)

    %{query: %{bool: bool}}
  end

  @spec build_clause(filter()) :: map()
  defp build_clause({:term, field, value}) do
    %{term: %{field => value}}
  end

  defp build_clause({:terms, field, values}) when is_list(values) do
    %{terms: %{field => values}}
  end

  defp build_clause({:range, field, bounds}) when is_map(bounds) do
    %{range: %{field => bounds}}
  end

  defp build_clause({:exists, field}) do
    %{exists: %{field: field}}
  end

  defp build_clause({:prefix, field, prefix}) when is_binary(prefix) do
    %{prefix: %{field => %{value: prefix}}}
  end

  defp build_clause({:nested, path, filters}) when is_binary(path) and is_list(filters) do
    inner_clauses = Enum.map(filters, &build_clause/1)

    %{
      nested: %{
        path: path,
        query: %{bool: %{must: inner_clauses}}
      }
    }
  end

  @spec put_if_present(map(), atom(), [map()]) :: map()
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, key, clauses), do: Map.put(map, key, clauses)

  @spec maybe_put_minimum_should_match(map(), [map()], pos_integer()) :: map()
  defp maybe_put_minimum_should_match(bool, [], _min), do: bool

  defp maybe_put_minimum_should_match(bool, _should, min) do
    Map.put(bool, :minimum_should_match, min)
  end
end
```
