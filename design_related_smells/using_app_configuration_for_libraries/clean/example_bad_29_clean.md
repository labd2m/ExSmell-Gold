```elixir
defmodule Paginator do
  @moduledoc """
  A library for offset-based pagination of enumerable collections and Ecto queries.

  Provides consistent pagination metadata including total counts, page numbers,
  and navigation helpers for building API responses and UI components.

  Expected application configuration:

      config :paginator,
        page_size: 25,
        max_page_size: 100,
        overflow_policy: :last_page   # :last_page | :empty
  """

  defstruct [
    :entries,
    :page_number,
    :page_size,
    :total_entries,
    :total_pages
  ]

  @type t :: %__MODULE__{
          entries:       list(),
          page_number:   pos_integer(),
          page_size:     pos_integer(),
          total_entries: non_neg_integer(),
          total_pages:   non_neg_integer()
        }

  @doc """
  Paginates a plain list of entries.

  Accepts a `page` parameter (1-based) to select which slice of data to return.
  Configuration is read from the application environment.
  """
  def paginate(entries, page \\ 1) when is_list(entries) do
    page_size       = Application.fetch_env!(:paginator, :page_size)
    max_page_size   = Application.fetch_env!(:paginator, :max_page_size)
    overflow_policy = Application.fetch_env!(:paginator, :overflow_policy)

    effective_size  = min(page_size, max_page_size)
    total_entries   = length(entries)
    total_pages     = ceil_div(total_entries, effective_size)

    safe_page =
      case overflow_policy do
        :last_page -> max(1, min(page, total_pages))
        :empty     -> page
      end

    offset  = (safe_page - 1) * effective_size
    slice   = Enum.slice(entries, offset, effective_size)

    %__MODULE__{
      entries:       slice,
      page_number:   safe_page,
      page_size:     effective_size,
      total_entries: total_entries,
      total_pages:   total_pages
    }
  end

  @doc """
  Paginates an Ecto query by injecting LIMIT and OFFSET clauses.

  Returns `{query_with_pagination, metadata}` where metadata contains
  pagination info. Requires a separate count query to compute totals.
  """
  def paginate_query(query, page \\ 1) do
    page_size     = Application.fetch_env!(:paginator, :page_size)
    max_page_size = Application.fetch_env!(:paginator, :max_page_size)

    effective_size = min(page_size, max_page_size)
    offset         = (max(1, page) - 1) * effective_size

    paginated_query =
      query
      |> apply_limit(effective_size)
      |> apply_offset(offset)

    meta = %{
      page_number: page,
      page_size:   effective_size,
      offset:      offset
    }

    {paginated_query, meta}
  end

  @doc """
  Builds a full metadata map from a page struct for use in API responses.
  """
  def metadata(%__MODULE__{} = page, base_url, params \\ %{}) do
    %{
      page:         page.page_number,
      per_page:     page.page_size,
      total:        page.total_entries,
      total_pages:  page.total_pages,
      first_url:    build_url(base_url, params, 1),
      last_url:     build_url(base_url, params, page.total_pages),
      prev_url:     prev_url(base_url, params, page),
      next_url:     next_url(base_url, params, page)
    }
  end

  @doc """
  Returns true if there are more pages after the current one.
  """
  def has_next?(%__MODULE__{page_number: p, total_pages: t}), do: p < t

  @doc """
  Returns true if there are pages before the current one.
  """
  def has_prev?(%__MODULE__{page_number: p}), do: p > 1

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ceil_div(_total, 0), do: 0
  defp ceil_div(total, size), do: div(total + size - 1, size)

  defp apply_limit(query, limit) do
    Map.update(query, :limit, limit, fn _ -> limit end)
  end

  defp apply_offset(query, offset) do
    Map.update(query, :offset, offset, fn _ -> offset end)
  end

  defp build_url(base, params, page) do
    query = URI.encode_query(Map.put(params, "page", page))
    "#{base}?#{query}"
  end

  defp prev_url(base, params, %{page_number: p} = page) do
    if has_prev?(page), do: build_url(base, params, p - 1), else: nil
  end

  defp next_url(base, params, %{page_number: p} = page) do
    if has_next?(page), do: build_url(base, params, p + 1), else: nil
  end
end
```
