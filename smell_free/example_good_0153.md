```elixir
defmodule Pagination.Cursor do
  @moduledoc """
  An opaque, URL-safe cursor encoding position and sort configuration
  for stable, keyset-based result pagination.

  Cursors are Base64-encoded JSON tokens. Decoding validates all fields
  against known atoms to prevent arbitrary atom creation from untrusted
  input.
  """

  @type direction :: :asc | :desc

  @type t :: %__MODULE__{
          after_value: term() | nil,
          after_id: String.t() | nil,
          sort_field: atom(),
          sort_direction: direction(),
          limit: pos_integer()
        }

  defstruct [:after_value, :after_id, sort_field: :id, sort_direction: :asc, limit: 20]

  @valid_directions ["asc", "desc"]

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = cursor) do
    payload = %{
      "after_value" => cursor.after_value,
      "after_id" => cursor.after_id,
      "sort_field" => Atom.to_string(cursor.sort_field),
      "sort_direction" => Atom.to_string(cursor.sort_direction),
      "limit" => cursor.limit
    }

    payload |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  @spec decode(String.t(), [atom()]) :: {:ok, t()} | {:error, :invalid_cursor}
  def decode(token, allowed_sort_fields) when is_binary(token) and is_list(allowed_sort_fields) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, raw} <- Jason.decode(json),
         {:ok, cursor} <- build_cursor(raw, allowed_sort_fields) do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp build_cursor(raw, allowed_sort_fields) do
    with {:ok, sort_field} <- parse_sort_field(raw["sort_field"], allowed_sort_fields),
         {:ok, sort_direction} <- parse_direction(raw["sort_direction"]),
         {:ok, limit} <- parse_limit(raw["limit"]) do
      cursor = %__MODULE__{
        after_value: raw["after_value"],
        after_id: raw["after_id"],
        sort_field: sort_field,
        sort_direction: sort_direction,
        limit: limit
      }

      {:ok, cursor}
    end
  end

  defp parse_sort_field(field, allowed) when is_binary(field) do
    atom = Enum.find(allowed, &(Atom.to_string(&1) == field))
    if atom, do: {:ok, atom}, else: {:error, :invalid_sort_field}
  end

  defp parse_sort_field(_, _), do: {:error, :invalid_sort_field}

  defp parse_direction(dir) when dir in @valid_directions, do: {:ok, String.to_existing_atom(dir)}
  defp parse_direction(_), do: {:error, :invalid_direction}

  defp parse_limit(n) when is_integer(n) and n > 0 and n <= 200, do: {:ok, n}
  defp parse_limit(_), do: {:error, :invalid_limit}
end

defmodule Pagination.CursorQuery do
  @moduledoc """
  Applies a `Pagination.Cursor` to an Ecto query to produce a keyset-paginated result.

  The query uses a (sort_field, id) composite condition rather than OFFSET
  so performance is stable regardless of how far into the result set the
  cursor points.
  """

  import Ecto.Query

  alias Pagination.Cursor

  @spec apply(Ecto.Queryable.t(), Cursor.t()) :: Ecto.Query.t()
  def apply(query, %Cursor{after_value: nil, limit: limit, sort_field: field, sort_direction: dir}) do
    query
    |> order_by([r], [{^dir, field(r, ^field)}, {:asc, r.id}])
    |> limit(^limit)
  end

  def apply(query, %Cursor{} = cursor) do
    %Cursor{
      after_value: after_value,
      after_id: after_id,
      sort_field: field,
      sort_direction: :asc,
      limit: limit
    } = cursor

    query
    |> where(
      [r],
      field(r, ^field) > ^after_value or
        (field(r, ^field) == ^after_value and r.id > ^after_id)
    )
    |> order_by([r], [{:asc, field(r, ^field)}, {:asc, r.id}])
    |> limit(^limit)
  end
end
```
