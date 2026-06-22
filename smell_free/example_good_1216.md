```elixir
defmodule Search.Filter do
  @moduledoc """
  A composable filter struct used to build scoped Ecto queries.
  Filters are constructed through explicit field setters and resolved
  into query constraints via `Search.QueryBuilder`.
  """

  defstruct [
    :term,
    :status,
    :inserted_after,
    :inserted_before,
    :min_amount_cents,
    :max_amount_cents,
    :owner_id,
    limit: 50,
    offset: 0
  ]

  @type t :: %__MODULE__{
          term: String.t() | nil,
          status: String.t() | nil,
          inserted_after: DateTime.t() | nil,
          inserted_before: DateTime.t() | nil,
          min_amount_cents: integer() | nil,
          max_amount_cents: integer() | nil,
          owner_id: integer() | nil,
          limit: pos_integer(),
          offset: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, list({atom(), String.t()})}
  def new(params) when is_map(params) do
    filter = %__MODULE__{
      term: Map.get(params, :term),
      status: Map.get(params, :status),
      inserted_after: Map.get(params, :inserted_after),
      inserted_before: Map.get(params, :inserted_before),
      min_amount_cents: Map.get(params, :min_amount_cents),
      max_amount_cents: Map.get(params, :max_amount_cents),
      owner_id: Map.get(params, :owner_id),
      limit: Map.get(params, :limit, 50),
      offset: Map.get(params, :offset, 0)
    }

    case validate(filter) do
      [] -> {:ok, filter}
      errors -> {:error, errors}
    end
  end

  defp validate(f) do
    []
    |> check_positive(:limit, f.limit)
    |> check_non_negative(:offset, f.offset)
    |> check_date_range(f.inserted_after, f.inserted_before)
    |> check_amount_range(f.min_amount_cents, f.max_amount_cents)
  end

  defp check_positive(errors, field, value) when not (is_integer(value) and value > 0) do
    [{field, "must be a positive integer"} | errors]
  end

  defp check_positive(errors, _field, _value), do: errors

  defp check_non_negative(errors, field, value) when not (is_integer(value) and value >= 0) do
    [{field, "must be a non-negative integer"} | errors]
  end

  defp check_non_negative(errors, _field, _value), do: errors

  defp check_date_range(errors, %DateTime{} = after_dt, %DateTime{} = before_dt) do
    if DateTime.compare(after_dt, before_dt) == :gt do
      [{:inserted_after, "must be before inserted_before"} | errors]
    else
      errors
    end
  end

  defp check_date_range(errors, _after, _before), do: errors

  defp check_amount_range(errors, min, max)
       when is_integer(min) and is_integer(max) and min > max do
    [{:min_amount_cents, "must be less than or equal to max_amount_cents"} | errors]
  end

  defp check_amount_range(errors, _min, _max), do: errors
end

defmodule Search.QueryBuilder do
  @moduledoc """
  Applies a `Search.Filter` to an Ecto queryable, building a composable
  pipeline of constraints without modifying any base schema logic.
  """

  import Ecto.Query

  alias Search.Filter

  @spec apply(Ecto.Queryable.t(), Filter.t()) :: Ecto.Query.t()
  def apply(base_query, %Filter{} = filter) do
    base_query
    |> apply_term(filter.term)
    |> apply_status(filter.status)
    |> apply_owner(filter.owner_id)
    |> apply_date_lower(filter.inserted_after)
    |> apply_date_upper(filter.inserted_before)
    |> apply_amount_lower(filter.min_amount_cents)
    |> apply_amount_upper(filter.max_amount_cents)
    |> apply_pagination(filter.limit, filter.offset)
  end

  defp apply_term(query, nil), do: query

  defp apply_term(query, term) when is_binary(term) do
    pattern = "%#{term}%"
    where(query, [r], ilike(r.name, ^pattern))
  end

  defp apply_status(query, nil), do: query
  defp apply_status(query, status), do: where(query, [r], r.status == ^status)

  defp apply_owner(query, nil), do: query
  defp apply_owner(query, owner_id), do: where(query, [r], r.owner_id == ^owner_id)

  defp apply_date_lower(query, nil), do: query

  defp apply_date_lower(query, dt) do
    where(query, [r], r.inserted_at >= ^dt)
  end

  defp apply_date_upper(query, nil), do: query

  defp apply_date_upper(query, dt) do
    where(query, [r], r.inserted_at <= ^dt)
  end

  defp apply_amount_lower(query, nil), do: query
  defp apply_amount_lower(query, min), do: where(query, [r], r.amount_cents >= ^min)

  defp apply_amount_upper(query, nil), do: query
  defp apply_amount_upper(query, max), do: where(query, [r], r.amount_cents <= ^max)

  defp apply_pagination(query, limit, offset) do
    query |> limit(^limit) |> offset(^offset)
  end
end
```
