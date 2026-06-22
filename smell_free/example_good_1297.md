**File:** `example_good_1297.md`

```elixir
defmodule Pagination.Cursor do
  @moduledoc """
  Encodes and decodes opaque pagination cursors for cursor-based
  pagination over Ecto result sets.
  """

  @spec encode(map()) :: String.t()
  def encode(fields) when is_map(fields) do
    fields
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @spec decode(String.t()) :: {:ok, map()} | {:error, :invalid_cursor}
  def decode(token) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, fields} <- Jason.decode(json, keys: :atoms) do
      {:ok, fields}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end

defmodule Pagination.Page do
  @moduledoc "Represents a single page of results with cursor metadata."

  @enforce_keys [:entries, :has_next_page]
  defstruct [:entries, :has_next_page, :next_cursor, :prev_cursor, :total_count]

  @type t :: %__MODULE__{
          entries: [term()],
          has_next_page: boolean(),
          next_cursor: String.t() | nil,
          prev_cursor: String.t() | nil,
          total_count: non_neg_integer() | nil
        }
end

defmodule Pagination.QueryBuilder do
  @moduledoc """
  Builds cursor-paginated Ecto queries. Supports forward and backward
  pagination over any sortable schema field.
  """

  import Ecto.Query

  alias Pagination.{Cursor, Page}

  @type sort_direction :: :asc | :desc
  @type options :: %{
          optional(:after) => String.t(),
          optional(:before) => String.t(),
          optional(:first) => pos_integer(),
          optional(:sort_field) => atom(),
          optional(:sort_dir) => sort_direction()
        }

  @default_page_size 20
  @max_page_size 100

  @spec paginate(Ecto.Query.t(), module(), options()) ::
          {:ok, Page.t()} | {:error, :invalid_cursor}
  def paginate(base_query, repo, opts) do
    page_size = min(Map.get(opts, :first, @default_page_size), @max_page_size)
    sort_field = Map.get(opts, :sort_field, :id)
    sort_dir = Map.get(opts, :sort_dir, :asc)

    with {:ok, cursor_values} <- resolve_cursor(opts) do
      query =
        base_query
        |> apply_cursor(cursor_values, sort_field, sort_dir)
        |> apply_sort(sort_field, sort_dir)
        |> limit(^(page_size + 1))

      raw_results = repo.all(query)
      has_next = length(raw_results) > page_size
      entries = Enum.take(raw_results, page_size)

      next_cursor =
        if has_next do
          last = List.last(entries)
          Cursor.encode(%{sort_field => Map.get(last, sort_field)})
        end

      {:ok, %Page{
        entries: entries,
        has_next_page: has_next,
        next_cursor: next_cursor,
        prev_cursor: nil
      }}
    end
  end

  defp resolve_cursor(%{after: token}) do
    Cursor.decode(token)
  end

  defp resolve_cursor(_opts), do: {:ok, nil}

  defp apply_cursor(query, nil, _field, _dir), do: query

  defp apply_cursor(query, cursor_values, field, :asc) do
    value = Map.get(cursor_values, field)
    where(query, [r], field(r, ^field) > ^value)
  end

  defp apply_cursor(query, cursor_values, field, :desc) do
    value = Map.get(cursor_values, field)
    where(query, [r], field(r, ^field) < ^value)
  end

  defp apply_sort(query, field, :asc), do: order_by(query, [r], asc: field(r, ^field))
  defp apply_sort(query, field, :desc), do: order_by(query, [r], desc: field(r, ^field))
end
```
