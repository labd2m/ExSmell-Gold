```elixir
defmodule Feeds.PaginatedCursor do
  @moduledoc """
  Implements opaque cursor-based pagination for any Ecto query. Cursors
  encode the sort column value and record ID of the last seen item so pages
  are stable under concurrent inserts. The cursor is Base64-encoded JSON,
  making it opaque to clients and safe to embed in URLs.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @type cursor :: String.t()
  @type page_opts :: [
          limit: pos_integer(),
          cursor: cursor() | nil,
          sort_by: atom(),
          sort_dir: :asc | :desc
        ]
  @type page(t) :: %{
          items: [t],
          next_cursor: cursor() | nil,
          has_more: boolean()
        }

  @default_limit 20
  @max_limit 100

  @doc """
  Executes a paginated query against `schema`. Returns items, a cursor for
  the next page, and a boolean indicating whether more items exist.
  """
  @spec paginate(Ecto.Queryable.t(), page_opts()) :: page(term())
  def paginate(queryable, opts \ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    cursor = Keyword.get(opts, :cursor)

    decoded = decode_cursor(cursor)

    results =
      queryable
      |> apply_cursor_condition(decoded, sort_by, sort_dir)
      |> order_by([q], [{^sort_dir, ^sort_by}, {^sort_dir, :id}])
      |> limit(^(limit + 1))
      |> Repo.all()

    has_more = length(results) > limit
    items = Enum.take(results, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(items), sort_by), else: nil

    %{items: items, next_cursor: next_cursor, has_more: has_more}
  end

  @doc "Decodes a cursor string. Returns `nil` for nil or invalid cursors."
  @spec decode_cursor(cursor() | nil) :: map() | nil
  def decode_cursor(nil), do: nil

  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, map} <- Jason.decode(json) do
      map
    else
      _ -> nil
    end
  end

  defp encode_cursor(nil, _sort_by), do: nil

  defp encode_cursor(item, sort_by) do
    value = Map.get(item, sort_by)
    encoded_value = encode_value(value)
    %{sort_value: encoded_value, id: item.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp apply_cursor_condition(query, nil, _sort_by, _dir), do: query

  defp apply_cursor_condition(query, %{"sort_value" => sv, "id" => id}, sort_by, :asc) do
    where(query, [q], {field(q, ^sort_by), q.id} > {^sv, ^id})
  end

  defp apply_cursor_condition(query, %{"sort_value" => sv, "id" => id}, sort_by, :desc) do
    where(query, [q], {field(q, ^sort_by), q.id} < {^sv, ^id})
  end

  defp apply_cursor_condition(query, _decoded, _sort_by, _dir), do: query

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(v), do: v
end
```
