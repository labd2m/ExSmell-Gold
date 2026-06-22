```elixir
defmodule Cursorpag.Page do
  @moduledoc """
  Cursor-based pagination for Ecto queries. Encodes the last-seen
  value of the sort column into an opaque cursor string. Clients pass
  the cursor back to fetch the next page without relying on numeric offsets.
  """

  import Ecto.Query

  @type cursor :: String.t()
  @type direction :: :asc | :desc
  @type sort_field :: atom()

  @type page_opts :: [
          limit: pos_integer(),
          cursor: cursor() | nil,
          sort_field: sort_field(),
          direction: direction()
        ]

  @type page_result(schema) :: %{
          entries: [schema],
          next_cursor: cursor() | nil,
          has_more: boolean(),
          count: non_neg_integer()
        }

  @spec paginate(Ecto.Queryable.t(), module(), page_opts()) :: page_result(term())
  def paginate(queryable, repo, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    cursor = Keyword.get(opts, :cursor)
    sort_field = Keyword.get(opts, :sort_field, :id)
    direction = Keyword.get(opts, :direction, :asc)

    entries =
      queryable
      |> apply_cursor(cursor, sort_field, direction)
      |> apply_order(sort_field, direction)
      |> limit(^(limit + 1))
      |> repo.all()

    has_more = length(entries) > limit
    page_entries = Enum.take(entries, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(page_entries), sort_field)

    %{
      entries: page_entries,
      next_cursor: next_cursor,
      has_more: has_more,
      count: length(page_entries)
    }
  end

  @spec encode_cursor(struct(), sort_field()) :: cursor()
  def encode_cursor(entry, sort_field) when is_struct(entry) and is_atom(sort_field) do
    value = Map.fetch!(entry, sort_field)
    raw = "#{sort_field}:#{serialize_value(value)}"
    Base.url_encode64(raw, padding: false)
  end

  @spec decode_cursor(cursor()) :: {:ok, {sort_field(), term()}} | {:error, String.t()}
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [field_str, value_str] <- String.split(raw, ":", parts: 2),
         field <- String.to_existing_atom(field_str) do
      {:ok, {field, value_str}}
    else
      _ -> {:error, "invalid cursor: #{inspect(cursor)}"}
    end
  rescue
    ArgumentError -> {:error, "invalid cursor field"}
  end

  @spec apply_cursor(Ecto.Queryable.t(), cursor() | nil, sort_field(), direction()) ::
          Ecto.Queryable.t()
  defp apply_cursor(queryable, nil, _field, _direction), do: queryable

  defp apply_cursor(queryable, cursor, sort_field, direction) do
    case decode_cursor(cursor) do
      {:ok, {^sort_field, raw_value}} ->
        apply_comparison(queryable, sort_field, raw_value, direction)

      {:ok, {other_field, _}} ->
        raise ArgumentError, "cursor sort field #{other_field} does not match #{sort_field}"

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  @spec apply_comparison(Ecto.Queryable.t(), sort_field(), String.t(), direction()) ::
          Ecto.Queryable.t()
  defp apply_comparison(queryable, field, raw_value, :asc) do
    where(queryable, [q], field(q, ^field) > ^raw_value)
  end

  defp apply_comparison(queryable, field, raw_value, :desc) do
    where(queryable, [q], field(q, ^field) < ^raw_value)
  end

  @spec apply_order(Ecto.Queryable.t(), sort_field(), direction()) :: Ecto.Queryable.t()
  defp apply_order(queryable, field, :asc), do: order_by(queryable, [q], asc: field(q, ^field))
  defp apply_order(queryable, field, :desc), do: order_by(queryable, [q], desc: field(q, ^field))

  @spec serialize_value(term()) :: String.t()
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(value) when is_binary(value), do: value
  defp serialize_value(value), do: to_string(value)
end

defmodule Cursorpag.Connection do
  @moduledoc """
  GraphQL-style connection wrapper around `Cursorpag.Page`.
  Adds edge/node structure and `page_info` metadata for
  clients that consume cursor pagination in a relay-compatible format.
  """

  alias Cursorpag.Page

  @type edge(schema) :: %{node: schema, cursor: Page.cursor()}
  @type page_info :: %{
          has_next_page: boolean(),
          end_cursor: Page.cursor() | nil
        }
  @type connection(schema) :: %{
          edges: [edge(schema)],
          page_info: page_info()
        }

  @spec from_page(Page.page_result(term()), atom()) :: connection(term())
  def from_page(%{entries: entries, next_cursor: next_cursor, has_more: has_more}, sort_field) do
    edges = Enum.map(entries, fn entry ->
      %{node: entry, cursor: Page.encode_cursor(entry, sort_field)}
    end)

    %{
      edges: edges,
      page_info: %{
        has_next_page: has_more,
        end_cursor: next_cursor
      }
    }
  end
end
```
