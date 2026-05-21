```elixir
defmodule API.PaginationHelper do
  use GenServer

  @moduledoc """
  Provides pagination utilities for list endpoints. Computes page metadata,
  offsets, and slices collections based on page number and size parameters.
  Used by the API layer to build consistent paginated responses.
  """


  @default_page_size 20
  @max_page_size     200

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Paginates an in-memory `list` using `params` (`%{page: int, page_size: int}`).
  Returns `{:ok, %{data: list_slice, meta: meta_map}}`.
  """
  def paginate(pid, list, params \\ %{}) do
    GenServer.call(pid, {:paginate, list, params})
  end

  @doc """
  Returns a pagination metadata map for database-level pagination where
  only the `total_count` is known (no full list in memory).
  """
  def page_meta(pid, total_count, params \\ %{}) do
    GenServer.call(pid, {:page_meta, total_count, params})
  end

  @doc "Returns the SQL OFFSET integer for a given page number and size."
  def offset(pid, page, page_size) do
    GenServer.call(pid, {:offset, page, page_size})
  end

  @doc "Returns the total number of pages for a given count and page size."
  def total_pages(pid, total_count, page_size) do
    GenServer.call(pid, {:total_pages, total_count, page_size})
  end

  @doc "Returns the clamped page_size between 1 and the max allowed."
  def clamp_page_size(pid, requested_size) do
    GenServer.call(pid, {:clamp_page_size, requested_size})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:paginate, list, params}, _from, state) do
    page      = max(Map.get(params, :page, 1), 1)
    page_size = params |> Map.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)
    total     = length(list)
    total_pgs = ceil(total / page_size)
    off       = (page - 1) * page_size
    slice     = Enum.slice(list, off, page_size)

    meta = %{
      page:          page,
      page_size:     page_size,
      total_count:   total,
      total_pages:   total_pgs,
      has_next:      page < total_pgs,
      has_previous:  page > 1
    }

    {:reply, {:ok, %{data: slice, meta: meta}}, state}
  end

  def handle_call({:page_meta, total_count, params}, _from, state) do
    page      = max(Map.get(params, :page, 1), 1)
    page_size = params |> Map.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)
    total_pgs = if total_count == 0, do: 0, else: ceil(total_count / page_size)

    meta = %{
      page:          page,
      page_size:     page_size,
      total_count:   total_count,
      total_pages:   total_pgs,
      offset:        (page - 1) * page_size,
      has_next:      page < total_pgs,
      has_previous:  page > 1,
      first_item:    if(total_count > 0, do: (page - 1) * page_size + 1, else: 0),
      last_item:     min(page * page_size, total_count)
    }

    {:reply, {:ok, meta}, state}
  end

  def handle_call({:offset, page, page_size}, _from, state) do
    {:reply, max(page - 1, 0) * page_size, state}
  end

  def handle_call({:total_pages, total_count, page_size}, _from, state) do
    pages = if total_count == 0, do: 0, else: ceil(total_count / page_size)
    {:reply, pages, state}
  end

  def handle_call({:clamp_page_size, size}, _from, state) do
    clamped = size |> max(1) |> min(@max_page_size)
    {:reply, clamped, state}
  end

end
```
