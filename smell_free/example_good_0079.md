```elixir
defmodule Analytics.FilterSpec do
  @moduledoc """
  A single composable filter condition applied when building an analytics query.
  """

  @type operator :: :eq | :neq | :gt | :gte | :lt | :lte | :in | :not_in

  @type t :: %__MODULE__{
          field: atom(),
          operator: operator(),
          value: term()
        }

  defstruct [:field, :operator, :value]

  @valid_operators [:eq, :neq, :gt, :gte, :lt, :lte, :in, :not_in]

  @spec new(atom(), operator(), term()) :: {:ok, t()} | {:error, :invalid_operator}
  def new(field, operator, value) when is_atom(field) do
    if operator in @valid_operators do
      {:ok, %__MODULE__{field: field, operator: operator, value: value}}
    else
      {:error, :invalid_operator}
    end
  end
end

defmodule Analytics.EventRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "analytics_events" do
    field :event_type, :string
    field :user_id, :string
    field :session_id, :string
    field :properties, :map
    field :occurred_at, :utc_datetime_usec
  end
end

defmodule Analytics.QueryBuilder do
  @moduledoc """
  Constructs composable Ecto query pipelines for analytics workloads.

  Callers assemble a query by providing a time range, a list of typed
  filter specs, optional grouping fields, and a row limit. Each stage
  of the pipeline produces a new `Ecto.Query` that can be inspected or
  further composed before being handed to a Repo for execution.
  """

  import Ecto.Query

  alias Analytics.{EventRecord, FilterSpec}

  @type build_opts :: [
          from: DateTime.t(),
          to: DateTime.t(),
          filters: [FilterSpec.t()],
          group_by: [atom()],
          order_by: [{:asc | :desc, atom()}],
          limit: pos_integer()
        ]

  @spec build(build_opts()) :: Ecto.Query.t()
  def build(opts) when is_list(opts) do
    from(e in EventRecord)
    |> apply_time_range(Keyword.get(opts, :from), Keyword.get(opts, :to))
    |> apply_filters(Keyword.get(opts, :filters, []))
    |> apply_group_by(Keyword.get(opts, :group_by, []))
    |> apply_order_by(Keyword.get(opts, :order_by, [desc: :occurred_at]))
    |> apply_limit(Keyword.get(opts, :limit, 1_000))
  end

  defp apply_time_range(query, nil, nil), do: query

  defp apply_time_range(query, %DateTime{} = from, nil) do
    from e in query, where: e.occurred_at >= ^from
  end

  defp apply_time_range(query, nil, %DateTime{} = to) do
    from e in query, where: e.occurred_at <= ^to
  end

  defp apply_time_range(query, %DateTime{} = from, %DateTime{} = to) do
    from e in query, where: e.occurred_at >= ^from and e.occurred_at <= ^to
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, &apply_single_filter(&2, &1))
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :eq, value: v}) do
    from e in query, where: field(e, ^f) == ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :neq, value: v}) do
    from e in query, where: field(e, ^f) != ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :gt, value: v}) do
    from e in query, where: field(e, ^f) > ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :gte, value: v}) do
    from e in query, where: field(e, ^f) >= ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :lt, value: v}) do
    from e in query, where: field(e, ^f) < ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :lte, value: v}) do
    from e in query, where: field(e, ^f) <= ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :in, value: v})
       when is_list(v) do
    from e in query, where: field(e, ^f) in ^v
  end

  defp apply_single_filter(query, %FilterSpec{field: f, operator: :not_in, value: v})
       when is_list(v) do
    from e in query, where: field(e, ^f) not in ^v
  end

  defp apply_group_by(query, []), do: query

  defp apply_group_by(query, fields) when is_list(fields) do
    from e in query, group_by: ^fields
  end

  defp apply_order_by(query, []), do: query

  defp apply_order_by(query, clauses) when is_list(clauses) do
    from e in query, order_by: ^clauses
  end

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0 do
    from e in query, limit: ^limit
  end
end
```
