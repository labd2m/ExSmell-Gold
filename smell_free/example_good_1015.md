```elixir
defmodule Platform.QueryPipeline do
  @moduledoc """
  A composable pipeline for building Ecto queries from structured filter,
  sort, and search parameters — typical of REST API list endpoints.

  Each filter and sort step is a plain function that takes a query and
  a value, returning a new query. Steps are applied only when the
  corresponding parameter is present, skipped otherwise.
  """

  import Ecto.Query, only: [from: 2, where: 3, order_by: 3, limit: 3, offset: 3]

  @type query :: Ecto.Query.t()
  @type filter_fn :: (query(), term() -> query())
  @type params :: map()

  @doc """
  Builds a query from `base` by applying any matching steps from
  `pipeline` to the provided `params`.

  `pipeline` is a keyword list of `{param_key, filter_fn}` pairs.
  Steps are applied in order; steps whose key is absent in `params` are skipped.
  """
  @spec build(query(), keyword(filter_fn()), params()) :: query()
  def build(base, pipeline, params) when is_list(pipeline) and is_map(params) do
    Enum.reduce(pipeline, base, fn {key, step_fn}, query ->
      case Map.get(params, to_string(key)) || Map.get(params, key) do
        nil -> query
        "" -> query
        value -> step_fn.(query, value)
      end
    end)
  end

  @doc "Returns a filter step that matches an exact value on `field`."
  @spec eq(atom()) :: filter_fn()
  def eq(field) when is_atom(field) do
    fn query, value -> where(query, [r], field(r, ^field) == ^value) end
  end

  @doc "Returns a filter step that performs a case-insensitive substring match on `field`."
  @spec ilike(atom()) :: filter_fn()
  def ilike(field) when is_atom(field) do
    fn query, value ->
      pattern = "%#{String.replace(value, "%", "\\%")}%"
      where(query, [r], ilike(field(r, ^field), ^pattern))
    end
  end

  @doc "Returns a filter step that matches values in a list on `field`."
  @spec in_list(atom()) :: filter_fn()
  def in_list(field) when is_atom(field) do
    fn query, value ->
      values = if is_list(value), do: value, else: String.split(value, ",")
      where(query, [r], field(r, ^field) in ^values)
    end
  end

  @doc "Returns a filter step for `field >= value`."
  @spec gte(atom()) :: filter_fn()
  def gte(field) when is_atom(field) do
    fn query, value -> where(query, [r], field(r, ^field) >= ^value) end
  end

  @doc "Returns a filter step for `field <= value`."
  @spec lte(atom()) :: filter_fn()
  def lte(field) when is_atom(field) do
    fn query, value -> where(query, [r], field(r, ^field) <= ^value) end
  end

  @doc "Returns a sort step that accepts `field_asc` or `field_desc` strings."
  @spec sort(atom()) :: filter_fn()
  def sort(default_field \\ :inserted_at) do
    fn query, value ->
      {field_str, direction} =
        case String.split(value, "_", parts: 2) do
          [f, "desc"] -> {f, :desc}
          [f, "asc"] -> {f, :asc}
          [f] -> {f, :asc}
          _ -> {Atom.to_string(default_field), :asc}
        end

      field = String.to_existing_atom(field_str)
      order_by(query, [r], [{^direction, field(r, ^field)}])
    rescue
      ArgumentError -> query
    end
  end

  @doc "Returns a pagination step. Applies `limit` and `offset` from page params."
  @spec paginate(pos_integer()) :: filter_fn()
  def paginate(default_per_page \\ 20) do
    fn query, params when is_map(params) ->
      per_page = parse_int(Map.get(params, "per_page"), default_per_page)
      page = parse_int(Map.get(params, "page"), 1)
      offset_val = (page - 1) * per_page

      query
      |> limit(^per_page)
      |> offset(^offset_val)
    end
  end

  @doc "Returns a step that applies a boolean scope when the value is truthy."
  @spec boolean_scope(atom(), (query() -> query())) :: filter_fn()
  def boolean_scope(flag, scope_fn) when is_atom(flag) and is_function(scope_fn, 1) do
    fn query, value ->
      if truthy?(value), do: scope_fn.(query), else: query
    end
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp parse_int(nil, default), do: default
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end
  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default
end
```
