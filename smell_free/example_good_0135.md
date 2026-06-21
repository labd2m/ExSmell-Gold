```elixir
defmodule MyApp.Repo.Paginator do
  @moduledoc """
  Cursor-based pagination for Ecto queries using opaque, Base64-encoded
  cursor tokens. Cursor pagination provides stable results when rows are
  inserted or deleted between pages, making it more reliable than offset
  pagination for feeds and activity streams.

  Cursors encode the sort field value and primary key of the last seen row.
  Only ascending order on a single sortable column is supported.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @default_limit 20
  @max_limit 100

  @type cursor :: String.t()
  @type sort_field :: atom()

  @type page(schema) :: %{
          entries: [schema],
          cursor_after: cursor() | nil,
          has_more: boolean(),
          limit: pos_integer()
        }

  @doc """
  Executes `query` with cursor-based pagination and returns a `page` map.

  ## Options

    * `:limit` - number of entries per page, capped at #{@max_limit} (default: #{@default_limit})
    * `:cursor` - opaque cursor string from a previous page response
    * `:sort_field` - the column used for ordering (default: `:inserted_at`)
  """
  @spec paginate(Ecto.Query.t(), keyword()) :: page(term())
  def paginate(query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    sort_field = Keyword.get(opts, :sort_field, :inserted_at)
    cursor = Keyword.get(opts, :cursor)

    entries =
      query
      |> apply_cursor(cursor, sort_field)
      |> order_by([q], [{:asc, field(q, ^sort_field)}, {:asc, q.id}])
      |> limit(^(limit + 1))
      |> Repo.all()

    has_more = length(entries) > limit
    page_entries = Enum.take(entries, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(page_entries), sort_field), else: nil

    %{
      entries: page_entries,
      cursor_after: next_cursor,
      has_more: has_more,
      limit: limit
    }
  end

  @spec apply_cursor(Ecto.Query.t(), cursor() | nil, sort_field()) :: Ecto.Query.t()
  defp apply_cursor(query, nil, _sort_field), do: query

  defp apply_cursor(query, cursor, sort_field) do
    case decode_cursor(cursor) do
      {:ok, %{sort_value: sv, id: id}} ->
        where(
          query,
          [q],
          {field(q, ^sort_field), q.id} > {^sv, ^id}
        )

      :error ->
        query
    end
  end

  @spec encode_cursor(struct(), sort_field()) :: cursor()
  defp encode_cursor(record, sort_field) do
    payload = %{
      sort_value: Map.fetch!(record, sort_field),
      id: record.id
    }

    payload
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  @spec decode_cursor(cursor()) :: {:ok, map()} | :error
  defp decode_cursor(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    _ -> :error
  end
end
```
