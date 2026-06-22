**File:** `example_good_1304.md`

```elixir
defmodule QueryBuilder.Filter do
  @moduledoc "Represents a single typed filter condition for a query."

  @enforce_keys [:field, :operator, :value]
  defstruct [:field, :operator, :value]

  @type operator :: :eq | :neq | :gt | :gte | :lt | :lte | :in | :like | :ilike
  @type t :: %__MODULE__{
          field: atom(),
          operator: operator(),
          value: term()
        }

  @valid_operators ~w(eq neq gt gte lt lte in like ilike)a

  @spec new(atom(), operator(), term()) :: {:ok, t()} | {:error, String.t()}
  def new(field, operator, value) when is_atom(field) do
    if operator in @valid_operators do
      {:ok, %__MODULE__{field: field, operator: operator, value: value}}
    else
      {:error, "unknown operator #{inspect(operator)}"}
    end
  end
end

defmodule QueryBuilder.Sort do
  @moduledoc "Represents a sort directive applied to a query."

  @enforce_keys [:field, :direction]
  defstruct [:field, :direction]

  @type direction :: :asc | :desc
  @type t :: %__MODULE__{field: atom(), direction: direction()}

  @spec new(atom(), direction()) :: {:ok, t()} | {:error, String.t()}
  def new(field, direction) when is_atom(field) and direction in [:asc, :desc] do
    {:ok, %__MODULE__{field: field, direction: direction}}
  end

  def new(_field, direction), do: {:error, "direction must be :asc or :desc, got #{inspect(direction)}"}
end

defmodule QueryBuilder do
  @moduledoc """
  Builds Ecto queries dynamically from a list of Filter and Sort structs.
  Intended for use by API controllers accepting structured filter parameters.
  """

  import Ecto.Query

  alias QueryBuilder.{Filter, Sort}

  @type query_spec :: %{
          optional(:filters) => [Filter.t()],
          optional(:sorts) => [Sort.t()],
          optional(:limit) => pos_integer(),
          optional(:offset) => non_neg_integer()
        }

  @spec apply(Ecto.Query.t(), query_spec()) :: Ecto.Query.t()
  def apply(base_query, spec) when is_map(spec) do
    base_query
    |> apply_filters(Map.get(spec, :filters, []))
    |> apply_sorts(Map.get(spec, :sorts, []))
    |> apply_limit(Map.get(spec, :limit))
    |> apply_offset(Map.get(spec, :offset))
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, &apply_filter(&2, &1))
  end

  defp apply_filter(query, %Filter{field: f, operator: :eq, value: v}),
    do: where(query, [r], field(r, ^f) == ^v)

  defp apply_filter(query, %Filter{field: f, operator: :neq, value: v}),
    do: where(query, [r], field(r, ^f) != ^v)

  defp apply_filter(query, %Filter{field: f, operator: :gt, value: v}),
    do: where(query, [r], field(r, ^f) > ^v)

  defp apply_filter(query, %Filter{field: f, operator: :gte, value: v}),
    do: where(query, [r], field(r, ^f) >= ^v)

  defp apply_filter(query, %Filter{field: f, operator: :lt, value: v}),
    do: where(query, [r], field(r, ^f) < ^v)

  defp apply_filter(query, %Filter{field: f, operator: :lte, value: v}),
    do: where(query, [r], field(r, ^f) <= ^v)

  defp apply_filter(query, %Filter{field: f, operator: :in, value: v}) when is_list(v),
    do: where(query, [r], field(r, ^f) in ^v)

  defp apply_filter(query, %Filter{field: f, operator: :like, value: v}),
    do: where(query, [r], like(field(r, ^f), ^"%#{v}%"))

  defp apply_filter(query, %Filter{field: f, operator: :ilike, value: v}),
    do: where(query, [r], ilike(field(r, ^f), ^"%#{v}%"))

  defp apply_sorts(query, sorts) do
    Enum.reduce(sorts, query, &apply_sort(&2, &1))
  end

  defp apply_sort(query, %Sort{field: f, direction: :asc}),
    do: order_by(query, [r], asc: field(r, ^f))

  defp apply_sort(query, %Sort{field: f, direction: :desc}),
    do: order_by(query, [r], desc: field(r, ^f))

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, lim), do: limit(query, ^lim)

  defp apply_offset(query, nil), do: query
  defp apply_offset(query, off), do: offset(query, ^off)
end
```
