```elixir
defmodule Pagination.Cursor do
  @moduledoc """
  An opaque cursor that encodes the last-seen record's sort key and ID,
  enabling stateless, stable keyset pagination over large ordered datasets.
  """

  @type t :: %__MODULE__{encoded: String.t()}
  defstruct [:encoded]

  @spec encode(term(), Ecto.UUID.t()) :: t()
  def encode(sort_value, record_id) when is_binary(record_id) do
    raw = :erlang.term_to_binary({sort_value, record_id})
    %__MODULE__{encoded: Base.url_encode64(raw, padding: false)}
  end

  @spec decode(t() | String.t()) :: {:ok, {term(), String.t()}} | {:error, :invalid_cursor}
  def decode(%__MODULE__{encoded: encoded}), do: decode(encoded)

  def decode(encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         {sort_value, id} when is_binary(id) <- :erlang.binary_to_term(raw, [:safe]) do
      {:ok, {sort_value, id}}
    rescue
      _ -> {:error, :invalid_cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end

defmodule Pagination.Page do
  @moduledoc """
  Represents a single page of results with navigation metadata.
  """

  @type t :: %__MODULE__{
          entries: list(),
          has_next: boolean(),
          next_cursor: Pagination.Cursor.t() | nil,
          count: non_neg_integer()
        }

  defstruct [:entries, :has_next, :next_cursor, :count]
end

defmodule Pagination do
  import Ecto.Query

  alias Pagination.{Cursor, Page}

  @moduledoc """
  Provides cursor-based keyset pagination for Ecto queries sorted by a
  single timestamp field and a UUID tiebreaker. Pages are stable across
  concurrent inserts and do not drift as new records are added.
  """

  @spec paginate(Ecto.Query.t(), MyApp.Repo, keyword()) ::
          {:ok, Page.t()} | {:error, :invalid_cursor}
  def paginate(base_query, repo, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    raw_cursor = Keyword.get(opts, :cursor)
    sort_field = Keyword.get(opts, :sort_by, :inserted_at)

    with {:ok, filtered_query} <- apply_cursor(base_query, raw_cursor, sort_field) do
      entries =
        filtered_query
        |> order_by([r], asc: field(r, ^sort_field), asc: r.id)
        |> limit(^(limit + 1))
        |> repo.all()

      has_next = length(entries) > limit
      page_entries = Enum.take(entries, limit)

      next_cursor =
        if has_next do
          last = List.last(page_entries)
          Cursor.encode(Map.fetch!(last, sort_field), last.id)
        end

      {:ok, %Page{entries: page_entries, has_next: has_next, next_cursor: next_cursor,
                  count: length(page_entries)}}
    end
  end

  defp apply_cursor(query, nil, _sort_field), do: {:ok, query}

  defp apply_cursor(query, raw_cursor, sort_field) do
    with {:ok, {sort_value, last_id}} <- Cursor.decode(raw_cursor) do
      filtered =
        where(
          query,
          [r],
          field(r, ^sort_field) > ^sort_value or
            (field(r, ^sort_field) == ^sort_value and r.id > ^last_id)
        )

      {:ok, filtered}
    end
  end
end
```
