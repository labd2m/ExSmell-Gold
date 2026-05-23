```elixir
defmodule Reporting.PaginationHelper do
  @moduledoc """
  Provides cursor-free offset-based pagination utilities for report
  exports, data grid queries, and API list endpoints. Produces
  standard pagination metadata compatible with JSON:API conventions.
  """

  require Logger

  @default_page_size 25
  @max_page_size 200
  @min_page 1

  @spec paginate(list(any()), integer(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def paginate(dataset, page, page_size)
      when is_list(dataset) and is_integer(page) and is_integer(page_size) do
    with :ok <- validate_page(page),
         :ok <- validate_page_size(page_size) do
      total = length(dataset)
      items = slice_results(dataset, page, page_size)
      meta = build_page_meta(page, page_size, total)

      {:ok,
       %{
         data: items,
         meta: meta,
         links: build_links(page, page_size, total)
       }}
    end
  end

  @spec build_page_meta(integer(), integer(), non_neg_integer()) :: map()
  def build_page_meta(page, page_size, total_count)
      when is_integer(page) and is_integer(page_size) and is_integer(total_count) do
    total_pages = ceil(total_count / page_size)
    offset = (page - 1) * page_size

    %{
      current_page: page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages,
      offset: offset,
      has_previous: page > @min_page,
      has_next: page < total_pages
    }
  end

  @spec next_page_params(integer(), integer(), non_neg_integer()) ::
          {:ok, {integer(), integer()}} | :end_of_results
  def next_page_params(page, page_size, total_count) do
    total_pages = ceil(total_count / max(page_size, 1))

    if page < total_pages do
      {:ok, {page + 1, page_size}}
    else
      :end_of_results
    end
  end

  @spec slice_results(list(any()), integer(), integer()) :: list(any())
  def slice_results(dataset, page, page_size) do
    offset = (page - 1) * page_size
    Enum.slice(dataset, offset, page_size)
  end

  @spec coerce_params(map()) :: {integer(), integer()}
  def coerce_params(params) do
    page =
      params
      |> Map.get("page", @min_page)
      |> to_positive_integer(@min_page)
      |> max(@min_page)

    page_size =
      params
      |> Map.get("page_size", @default_page_size)
      |> to_positive_integer(@default_page_size)
      |> min(@max_page_size)
      |> max(1)

    Logger.debug("Pagination coerced: page=#{page}, page_size=#{page_size}")
    {page, page_size}
  end

  @spec page_range(integer(), integer(), non_neg_integer()) :: Range.t()
  def page_range(page, page_size, total_count) do
    total_pages = max(ceil(total_count / page_size), 1)
    first = max(page - 2, @min_page)
    last = min(page + 2, total_pages)
    first..last
  end

  defp build_links(page, page_size, total_count) do
    total_pages = ceil(total_count / max(page_size, 1))

    %{
      self: build_page_link(page, page_size),
      first: build_page_link(@min_page, page_size),
      last: build_page_link(total_pages, page_size),
      prev: if(page > @min_page, do: build_page_link(page - 1, page_size), else: nil),
      next: if(page < total_pages, do: build_page_link(page + 1, page_size), else: nil)
    }
  end

  defp build_page_link(page, page_size) do
    "?page=#{page}&page_size=#{page_size}"
  end

  defp validate_page(page) do
    if page >= @min_page do
      :ok
    else
      {:error, "Page must be >= #{@min_page}, got #{page}"}
    end
  end

  defp validate_page_size(page_size) do
    cond do
      page_size < 1 ->
        {:error, "page_size must be at least 1, got #{page_size}"}

      page_size > @max_page_size ->
        {:error, "page_size #{page_size} exceeds maximum of #{@max_page_size}"}

      true ->
        :ok
    end
  end

  defp to_positive_integer(value, default) when is_integer(value) and value > 0, do: value
  defp to_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp to_positive_integer(_, default), do: default
end
```
