```elixir
defmodule Api.PaginationCalculator do
  use GenServer

  @moduledoc """
  Computes pagination metadata for list endpoints.
  Consumed by REST controllers and GraphQL resolvers before serializing
  collection responses to clients.
  """

  @default_page_size 25
  @max_page_size 100
  @visible_window 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns a full pagination metadata map.

  ## Example result
      %{page: 2, page_size: 25, total_count: 143, total_pages: 6,
        has_next: true, has_prev: true, next_page: 3, prev_page: 1}
  """
  def metadata(pid, total_count, opts \\ []) do
    GenServer.call(pid, {:metadata, total_count, opts})
  end

  @doc """
  Returns the list of page numbers that should be shown in a pagination widget.
  Always includes the first and last page; fills in a window around the current page.
  """
  def visible_pages(pid, total_pages, current_page) do
    GenServer.call(pid, {:visible_pages, total_pages, current_page})
  end

  @doc """
  Returns the zero-based record offset for a given page and page size.
  """
  def offset(pid, page, page_size) do
    GenServer.call(pid, {:offset, page, page_size})
  end

  @doc """
  Returns `{first_record, last_record}` (1-based, inclusive) shown on the page.
  """
  def page_range(pid, page, page_size, total_count) do
    GenServer.call(pid, {:page_range, page, page_size, total_count})
  end

  @doc """
  Clamps a raw page-size value to the permitted range.
  """
  def clamp_page_size(pid, requested_size) do
    GenServer.call(pid, {:clamp_page_size, requested_size})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:metadata, total_count, opts}, _from, state) do
    page      = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, @default_page_size) |> clamp(1, @max_page_size)
    total_pages = ceil_div(total_count, page_size)
    safe_page   = min(page, max(total_pages, 1))

    result = %{
      page:        safe_page,
      page_size:   page_size,
      total_count: total_count,
      total_pages: total_pages,
      has_next:    safe_page < total_pages,
      has_prev:    safe_page > 1,
      next_page:   if(safe_page < total_pages, do: safe_page + 1, else: nil),
      prev_page:   if(safe_page > 1, do: safe_page - 1, else: nil),
      offset:      (safe_page - 1) * page_size
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:visible_pages, total_pages, current}, _from, state) do
    window_start = max(current - @visible_window, 1)
    window_end   = min(current + @visible_window, total_pages)

    pages =
      ([1] ++ Enum.to_list(window_start..window_end) ++ [total_pages])
      |> Enum.uniq()
      |> Enum.sort()
      |> insert_ellipsis()

    {:reply, {:ok, pages}, state}
  end

  @impl true
  def handle_call({:offset, page, page_size}, _from, state) do
    {:reply, {:ok, (max(page, 1) - 1) * page_size}, state}
  end

  @impl true
  def handle_call({:page_range, page, page_size, total_count}, _from, state) do
    first = (page - 1) * page_size + 1
    last  = min(page * page_size, total_count)
    {:reply, {:ok, {first, last}}, state}
  end

  @impl true
  def handle_call({:clamp_page_size, size}, _from, state) do
    {:reply, {:ok, clamp(size, 1, @max_page_size)}, state}
  end


  defp ceil_div(_total, 0), do: 1
  defp ceil_div(total, size), do: div(total + size - 1, size)

  defp clamp(value, min_val, max_val), do: value |> max(min_val) |> min(max_val)

  defp insert_ellipsis([]), do: []
  defp insert_ellipsis(pages) do
    pages
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce([hd(pages)], fn [a, b], acc ->
      if b - a > 1 do
        acc ++ [:ellipsis, b]
      else
        acc ++ [b]
      end
    end)
  end
end
```
