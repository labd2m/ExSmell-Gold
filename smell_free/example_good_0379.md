```elixir
defmodule Pagination.Keyset do
  @moduledoc """
  Implements cursor-based (keyset) pagination for Ecto queries.
  Unlike offset pagination, keyset pagination remains performant on large
  tables because it avoids full-table scans. The cursor is an opaque,
  Base64-encoded term that encodes the last seen sort values, allowing the
  database to seek directly to the next page using an index range scan.
  Supports single- and multi-column ordering in both `:asc` and `:desc`
  directions.
  """

  import Ecto.Query

  @type cursor :: binary()
  @type direction :: :asc | :desc
  @type order_field :: {atom(), direction()}

  @type page_opts :: [
          cursor: cursor() | nil,
          limit: pos_integer(),
          order_by: [order_field()]
        ]

  @type page_result(schema) :: %{
          entries: [schema],
          next_cursor: cursor() | nil,
          has_more: boolean()
        }

  @default_limit 25
  @max_limit 200

  @doc """
  Paginates `queryable` using keyset semantics. Accepts an optional
  `:cursor` decoded from a prior response, a `:limit`, and `:order_by`
  field/direction pairs. Returns a result map with `entries`,
  `next_cursor`, and `has_more`.
  """
  @spec paginate(Ecto.Queryable.t(), module(), page_opts()) :: page_result(struct())
  def paginate(queryable, repo, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)
    order_fields = Keyword.get(opts, :order_by, [id: :asc])
    cursor = Keyword.get(opts, :cursor)

    cursor_values = decode_cursor(cursor)

    entries =
      queryable
      |> apply_cursor_condition(cursor_values, order_fields)
      |> apply_order(order_fields)
      |> limit(^(limit + 1))
      |> repo.all()

    has_more = length(entries) > limit
    page_entries = Enum.take(entries, limit)
    next_cursor = if has_more, do: encode_cursor(List.last(page_entries), order_fields), else: nil

    %{entries: page_entries, next_cursor: next_cursor, has_more: has_more}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_cursor_condition(query, nil, _order_fields), do: query

  defp apply_cursor_condition(query, cursor_values, order_fields) do
    conditions = build_cursor_conditions(order_fields, cursor_values)
    where(query, ^conditions)
  end

  defp build_cursor_conditions([{field, :asc}], [value]) do
    dynamic([q], field(q, ^field) > ^value)
  end

  defp build_cursor_conditions([{field, :desc}], [value]) do
    dynamic([q], field(q, ^field) < ^value)
  end

  defp build_cursor_conditions([{field, :asc} | rest_fields], [value | rest_values]) do
    tail = build_cursor_conditions(rest_fields, rest_values)
    dynamic([q], field(q, ^field) > ^value or (field(q, ^field) == ^value and ^tail))
  end

  defp build_cursor_conditions([{field, :desc} | rest_fields], [value | rest_values]) do
    tail = build_cursor_conditions(rest_fields, rest_values)
    dynamic([q], field(q, ^field) < ^value or (field(q, ^field) == ^value and ^tail))
  end

  defp apply_order(query, order_fields) do
    Enum.reduce(order_fields, query, fn {field, direction}, q ->
      order_by(q, [r], [{^direction, field(r, ^field)}])
    end)
  end

  defp encode_cursor(record, order_fields) do
    values = Enum.map(order_fields, fn {field, _dir} -> Map.fetch!(record, field) end)

    values
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    cursor
    |> Base.url_decode64!(padding: false)
    |> :erlang.binary_to_term([:safe])
  rescue
    _ -> nil
  end
end
```
