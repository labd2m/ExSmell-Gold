```elixir
defmodule Platform.CursorPagination do
  @moduledoc """
  Keyset (cursor-based) pagination for Ecto queries.

  Unlike offset pagination, keyset pagination maintains constant performance
  at any page depth and remains stable under concurrent inserts or deletes.
  Cursors encode the sort key of the last-seen row and are URL-safe strings.
  """

  import Ecto.Query, only: [from: 2, order_by: 3, limit: 3]
  alias Platform.Repo

  @type cursor :: String.t()
  @type sort_field :: :inserted_at | :updated_at | :id
  @type page(schema) :: %{
          data: [schema],
          next_cursor: cursor() | nil,
          has_more: boolean(),
          count: non_neg_integer()
        }

  @doc """
  Returns a page of at most `limit` rows following the position encoded in `cursor`.

  Rows are ordered by `(inserted_at ASC, id ASC)`. Pass `cursor: nil` to fetch
  the first page. Returns `{:error, :invalid_cursor}` for a malformed cursor.
  """
  @spec paginate(Ecto.Queryable.t(), pos_integer(), cursor() | nil) ::
          {:ok, page(struct())} | {:error, :invalid_cursor}
  def paginate(queryable, limit, cursor \\ nil) when is_integer(limit) and limit > 0 do
    with {:ok, position} <- decode_cursor(cursor) do
      rows =
        queryable
        |> apply_position_filter(position)
        |> order_by([q], asc: q.inserted_at, asc: q.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      has_more = length(rows) > limit
      data = Enum.take(rows, limit)
      next = if has_more, do: encode_cursor(List.last(data)), else: nil

      {:ok, %{data: data, next_cursor: next, has_more: has_more, count: length(data)}}
    end
  end

  @doc """
  Wraps paginate results in a standard envelope with pagination metadata.
  Accepts the same arguments as `paginate/3`.
  """
  @spec paginate_envelope(Ecto.Queryable.t(), pos_integer(), cursor() | nil) :: map()
  def paginate_envelope(queryable, limit, cursor \\ nil) do
    case paginate(queryable, limit, cursor) do
      {:ok, page} ->
        %{data: page.data, meta: %{next_cursor: page.next_cursor, has_more: page.has_more, count: page.count}}

      {:error, :invalid_cursor} ->
        %{data: [], meta: %{next_cursor: nil, has_more: false, count: 0, error: "invalid_cursor"}}
    end
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"id" => id, "inserted_at" => ts}} <- Jason.decode(json),
         {:ok, datetime, _} <- DateTime.from_iso8601(ts) do
      {:ok, %{id: id, inserted_at: datetime}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp apply_position_filter(query, nil), do: query

  defp apply_position_filter(query, %{id: id, inserted_at: inserted_at}) do
    from(q in query,
      where: q.inserted_at > ^inserted_at or (q.inserted_at == ^inserted_at and q.id > ^id)
    )
  end

  defp encode_cursor(%{id: id, inserted_at: %DateTime{} = inserted_at}) do
    payload = Jason.encode!(%{id: id, inserted_at: DateTime.to_iso8601(inserted_at)})
    Base.url_encode64(payload, padding: false)
  end
end
```
