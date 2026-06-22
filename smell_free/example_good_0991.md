```elixir
defmodule Api.PaginationStream do
  @moduledoc """
  Produces a lazy `Stream.t()` over a cursor- or offset-paginated external
  REST API. Each page is fetched only when the stream is consumed, making
  the abstraction composable with `Stream.take/2`, `Enum.filter/2`, and
  other lazy operations without over-fetching. Both cursor-based and
  offset-based pagination are supported through a common stream interface.
  """

  require Logger

  @type page_result :: %{
          items: [map()],
          next_cursor: binary() | nil,
          has_more: boolean()
        }

  @type fetch_fn :: (map() -> {:ok, page_result()} | {:error, term()})

  @doc """
  Returns a lazy stream over cursor-paginated API results.
  `fetch_fn` receives a map of query params including `"cursor"` and must
  return `{:ok, %{items: [...], next_cursor: cursor_or_nil, has_more: bool}}`.

  ## Example

      PaginationStream.cursor_stream(fn params ->
        StripeClient.list_customers(params)
      end)
      |> Stream.filter(&(&1["email"] =~ "@corp.example"))
      |> Enum.take(50)
  """
  @spec cursor_stream(fetch_fn(), map()) :: Enumerable.t()
  def cursor_stream(fetch_fn, initial_params \\ %{}) when is_function(fetch_fn, 1) do
    Stream.resource(
      fn -> {:start, initial_params} end,
      fn
        :done ->
          {:halt, :done}

        {:start, params} ->
          fetch_page(fetch_fn, params, :cursor)

        {:cursor, cursor, params} ->
          fetch_page(fetch_fn, Map.put(params, "cursor", cursor), :cursor)
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Returns a lazy stream over offset-paginated API results.
  `fetch_fn` receives a map of query params including `"page"` and `"per_page"`.
  Stops when a page returns fewer items than `per_page` or an empty page.
  """
  @spec offset_stream(fetch_fn(), map()) :: Enumerable.t()
  def offset_stream(fetch_fn, initial_params \\ %{}) when is_function(fetch_fn, 1) do
    per_page = Map.get(initial_params, "per_page", 100)

    Stream.resource(
      fn -> {:page, 1, initial_params} end,
      fn
        :done ->
          {:halt, :done}

        {:page, page_num, params} ->
          page_params = Map.merge(params, %{"page" => page_num, "per_page" => per_page})

          case fetch_fn.(page_params) do
            {:ok, %{items: []}} ->
              {[], :done}

            {:ok, %{items: items}} when length(items) < per_page ->
              {items, :done}

            {:ok, %{items: items}} ->
              {items, {:page, page_num + 1, params}}

            {:error, reason} ->
              Logger.error("Offset pagination fetch failed",
                page: page_num,
                reason: inspect(reason)
              )

              {[], :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Collects all pages into a list, logging the total fetched.
  Convenience wrapper for cases where the full dataset is needed.
  """
  @spec collect_all(Enumerable.t()) :: {:ok, [map()]} | {:error, term()}
  def collect_all(stream) do
    items = Enum.to_list(stream)
    Logger.info("Pagination stream collected", item_count: length(items))
    {:ok, items}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_page(fetch_fn, params, type) do
    case fetch_fn.(params) do
      {:ok, %{items: items, next_cursor: nil}} ->
        {items, :done}

      {:ok, %{items: items, next_cursor: cursor, has_more: true}} ->
        {items, {type, cursor, Map.delete(params, "cursor")}}

      {:ok, %{items: items}} ->
        {items, :done}

      {:error, reason} ->
        Logger.error("Cursor pagination fetch failed",
          params: Map.delete(params, "api_key"),
          reason: inspect(reason)
        )

        {[], :done}
    end
  end
end
```
