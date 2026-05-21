# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `Paginator.paginate/2`
- **Affected function(s):** `paginate/2`, `build_meta/3`
- **Short explanation:** The library reads `:default_page_size` and `:max_page_size` from the global `Application Environment` rather than accepting them as keyword options. Any consumer of this library must use the same pagination sizes across the entire application, making it impossible to return 10 items for a mobile endpoint and 100 items for a bulk-export endpoint without changing global configuration.

```elixir
defmodule Paginator do
  @moduledoc """
  A library for applying cursor-based and offset-based pagination to
  Ecto queries or plain Elixir lists. Intended for reuse across API
  controllers and background reporting jobs.

  Configuration (config/config.exs):

      config :paginator,
        default_page_size: 20,
        max_page_size: 100
  """

  require Logger

  @type page_params :: %{
          optional(:page) => pos_integer(),
          optional(:page_size) => pos_integer(),
          optional(:cursor) => String.t() | nil
        }

  @type page_meta :: %{
          page: pos_integer(),
          page_size: pos_integer(),
          total_count: non_neg_integer(),
          total_pages: pos_integer(),
          has_next: boolean(),
          has_prev: boolean()
        }

  @doc """
  Paginates a list of items according to the given page parameters.
  The default and maximum page sizes are read from application configuration.

  ## Parameters

    - `items` – the full collection to paginate.
    - `params` – a map with optional keys `:page` and `:page_size`.

  ## Returns

  `{:ok, page_items, meta}` or `{:error, reason}`.
  """
  @spec paginate(list(), page_params()) ::
          {:ok, list(), page_meta()} | {:error, String.t()}
  def paginate(items, params \\ %{}) when is_list(items) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library fetches :default_page_size
    # and :max_page_size from the global Application Environment instead of
    # accepting them as optional keyword arguments. Callers in the same app
    # cannot use page size 10 for a mobile API response and page size 100 for
    # a data export job—they are all forced to share the one globally configured
    # default and maximum, making the library unnecessarily rigid for reuse.
    default_size = Application.fetch_env!(:paginator, :default_page_size)
    max_size = Application.fetch_env!(:paginator, :max_page_size)
    # VALIDATION: SMELL END

    requested_size = Map.get(params, :page_size, default_size)
    page_size = min(requested_size, max_size)
    page = max(Map.get(params, :page, 1), 1)

    if page_size < 1 do
      {:error, "page_size must be a positive integer"}
    else
      total_count = length(items)
      total_pages = max(ceil(total_count / page_size), 1)
      safe_page = min(page, total_pages)
      offset = (safe_page - 1) * page_size

      page_items = Enum.slice(items, offset, page_size)

      meta = build_meta(safe_page, page_size, total_count)

      Logger.debug("[Paginator] page=#{safe_page}/#{total_pages} size=#{page_size} total=#{total_count}")

      {:ok, page_items, meta}
    end
  end

  @doc """
  Generates a cursor token for the last item in a page.
  Used for cursor-based pagination workflows.
  """
  @spec encode_cursor(map()) :: String.t()
  def encode_cursor(item) when is_map(item) do
    item
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Decodes a cursor token back into the original map.
  """
  @spec decode_cursor(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_cursor(token) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, "Invalid or corrupted cursor token"}
    end
  end

  @doc """
  Builds the pagination link headers for an HTTP response.
  """
  @spec build_links(String.t(), page_meta()) :: list({String.t(), String.t()})
  def build_links(base_url, %{page: page, page_size: size, total_pages: total}) do
    links = [{"first", "#{base_url}?page=1&page_size=#{size}"}]

    links =
      if page > 1,
        do: [{"prev", "#{base_url}?page=#{page - 1}&page_size=#{size}"} | links],
        else: links

    links =
      if page < total,
        do: [{"next", "#{base_url}?page=#{page + 1}&page_size=#{size}"} | links],
        else: links

    [{"last", "#{base_url}?page=#{total}&page_size=#{size}"} | links]
  end

  # --- Private helpers ---

  defp build_meta(page, page_size, total_count) do
    total_pages = max(ceil(total_count / page_size), 1)

    %{
      page: page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_prev: page > 1
    }
  end
end
```
