```elixir
defmodule Pagination.Cursor do
  @moduledoc """
  Cursor-based pagination for Ecto queries using opaque encoded cursors.

  Cursor pagination provides stable results when records are inserted between
  pages, unlike offset-based approaches. Cursors encode the sort field value
  and ID of the last seen record.
  """

  import Ecto.Query

  alias Pagination.Cursor.{Page, CursorCodec}

  @default_limit 20
  @max_limit 100

  @doc """
  Paginates an Ecto queryable using cursor-based navigation.

  Accepts an optional `:after` cursor and `:limit`. Returns a `Page` struct
  containing records, a next-page cursor, and a boolean indicating whether
  more records exist.
  """
  @spec paginate(Ecto.Queryable.t(), module(), keyword()) :: Page.t()
  def paginate(queryable, repo, opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
    cursor_string = Keyword.get(opts, :after)
    sort_field = Keyword.get(opts, :sort_field, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)

    base_query =
      queryable
      |> apply_cursor_filter(cursor_string, sort_field, sort_dir)
      |> apply_order(sort_field, sort_dir)
      |> limit(^(limit + 1))

    results = repo.all(base_query)
    has_more = length(results) > limit
    records = Enum.take(results, limit)

    next_cursor =
      if has_more do
        last = List.last(records)
        CursorCodec.encode(Map.get(last, sort_field), last.id)
      else
        nil
      end

    Page.new(records, next_cursor, has_more)
  end

  defp apply_cursor_filter(query, nil, _sort_field, _sort_dir), do: query

  defp apply_cursor_filter(query, cursor_string, sort_field, :asc) do
    case CursorCodec.decode(cursor_string) do
      {:ok, {sort_value, last_id}} ->
        where(query, [r],
          field(r, ^sort_field) > ^sort_value or
            (field(r, ^sort_field) == ^sort_value and r.id > ^last_id)
        )

      :error ->
        query
    end
  end

  defp apply_cursor_filter(query, cursor_string, sort_field, :desc) do
    case CursorCodec.decode(cursor_string) do
      {:ok, {sort_value, last_id}} ->
        where(query, [r],
          field(r, ^sort_field) < ^sort_value or
            (field(r, ^sort_field) == ^sort_value and r.id < ^last_id)
        )

      :error ->
        query
    end
  end

  defp apply_order(query, sort_field, :asc) do
    order_by(query, [r], [{:asc, field(r, ^sort_field)}, {:asc, r.id}])
  end

  defp apply_order(query, sort_field, :desc) do
    order_by(query, [r], [{:desc, field(r, ^sort_field)}, {:desc, r.id}])
  end
end

defmodule Pagination.Cursor.Page do
  @moduledoc "Typed result of a cursor-paginated query."

  @enforce_keys [:records, :has_more]
  defstruct [:records, :next_cursor, :has_more]

  @type t :: %__MODULE__{
          records: [struct()],
          next_cursor: String.t() | nil,
          has_more: boolean()
        }

  @spec new([struct()], String.t() | nil, boolean()) :: t()
  def new(records, next_cursor, has_more) do
    %__MODULE__{records: records, next_cursor: next_cursor, has_more: has_more}
  end
end

defmodule Pagination.Cursor.CursorCodec do
  @moduledoc "Encodes and decodes opaque pagination cursors."

  @spec encode(term(), String.t()) :: String.t()
  def encode(sort_value, id) when is_binary(id) do
    payload = :erlang.term_to_binary({sort_value, id})
    Base.url_encode64(payload, padding: false)
  end

  @spec decode(String.t()) :: {:ok, {term(), String.t()}} | :error
  def decode(cursor) when is_binary(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {sort_value, id} when is_binary(id) <- :erlang.binary_to_term(binary, [:safe]) do
      {:ok, {sort_value, id}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
```
