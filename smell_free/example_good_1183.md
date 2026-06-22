```elixir
defmodule Pagination.CursorPage do
  @moduledoc """
  Provides opaque cursor-based pagination over Ecto queries.
  Cursors encode the last-seen row's sort key and ID, enabling
  stable forward and backward traversal over large datasets.
  """

  import Ecto.Query

  alias Pagination.Cursor

  @type direction :: :forward | :backward
  @type page_opts :: [
          cursor: String.t() | nil,
          limit: pos_integer(),
          direction: direction(),
          order_by: atom()
        ]

  @type page(t) :: %{
          entries: [t],
          start_cursor: String.t() | nil,
          end_cursor: String.t() | nil,
          has_previous: boolean(),
          has_next: boolean()
        }

  @default_limit 25
  @max_limit 100

  @spec paginate(Ecto.Query.t(), Ecto.Repo.t(), page_opts()) :: page(term())
  def paginate(base_query, repo, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    direction = Keyword.get(opts, :direction, :forward)
    order_field = Keyword.get(opts, :order_by, :inserted_at)
    raw_cursor = Keyword.get(opts, :cursor)

    cursor = decode_cursor(raw_cursor)
    fetch_limit = limit + 1

    rows =
      base_query
      |> apply_cursor_condition(cursor, order_field, direction)
      |> apply_order(order_field, direction)
      |> limit(^fetch_limit)
      |> repo.all()

    has_more = length(rows) > limit
    entries = Enum.take(rows, limit)
    entries = if direction == :backward, do: Enum.reverse(entries), else: entries

    %{
      entries: entries,
      start_cursor: encode_cursor(List.first(entries), order_field),
      end_cursor: encode_cursor(List.last(entries), order_field),
      has_previous: direction == :backward && has_more,
      has_next: direction == :forward && has_more
    }
  end

  @spec apply_cursor_condition(Ecto.Query.t(), map() | nil, atom(), direction()) ::
          Ecto.Query.t()
  defp apply_cursor_condition(query, nil, _field, _direction), do: query

  defp apply_cursor_condition(query, %{value: value, id: id}, field, :forward) do
    from(r in query,
      where:
        field(r, ^field) > ^value or
          (field(r, ^field) == ^value and r.id > ^id)
    )
  end

  defp apply_cursor_condition(query, %{value: value, id: id}, field, :backward) do
    from(r in query,
      where:
        field(r, ^field) < ^value or
          (field(r, ^field) == ^value and r.id < ^id)
    )
  end

  @spec apply_order(Ecto.Query.t(), atom(), direction()) :: Ecto.Query.t()
  defp apply_order(query, field, :forward) do
    from(r in query, order_by: [asc: field(r, ^field), asc: r.id])
  end

  defp apply_order(query, field, :backward) do
    from(r in query, order_by: [desc: field(r, ^field), desc: r.id])
  end

  @spec encode_cursor(map() | nil, atom()) :: String.t() | nil
  defp encode_cursor(nil, _field), do: nil

  defp encode_cursor(row, field) do
    %{value: Map.fetch!(row, field), id: row.id}
    |> Cursor.encode()
  end

  @spec decode_cursor(String.t() | nil) :: map() | nil
  defp decode_cursor(nil), do: nil
  defp decode_cursor(encoded), do: Cursor.decode(encoded)
end
```
