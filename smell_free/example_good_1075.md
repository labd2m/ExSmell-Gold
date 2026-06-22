**File:** `example_good_1075.md`

```elixir
defmodule SearchWeb.ProductSearchLive do
  @moduledoc """
  LiveView for interactive product search with debounced query input,
  pagination, and filter state management. Search results are fetched
  asynchronously to keep the UI responsive during slow queries.
  """

  use Phoenix.LiveView

  alias Inventory.Products
  alias SearchWeb.SearchForm

  @debounce_ms 300
  @page_size 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:query, "")
      |> assign(:filters, SearchForm.default_filters())
      |> assign(:results, [])
      |> assign(:total_count, 0)
      |> assign(:page, 1)
      |> assign(:loading, false)
      |> assign(:search_timer, nil)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("search_input", %{"query" => query}, socket) do
    cancel_pending_search(socket.assigns.search_timer)
    timer = Process.send_after(self(), {:execute_search, query}, @debounce_ms)

    socket =
      socket
      |> assign(:query, query)
      |> assign(:loading, true)
      |> assign(:search_timer, timer)

    {:noreply, socket}
  end

  def handle_event("apply_filter", %{"filter" => key, "value" => value}, socket) do
    updated_filters = Map.put(socket.assigns.filters, key, value)

    socket =
      socket
      |> assign(:filters, updated_filters)
      |> assign(:page, 1)

    {:noreply, trigger_search(socket)}
  end

  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:filters, SearchForm.default_filters())
      |> assign(:page, 1)

    {:noreply, trigger_search(socket)}
  end

  def handle_event("next_page", _params, %{assigns: %{page: page}} = socket) do
    {:noreply, socket |> assign(:page, page + 1) |> trigger_search()}
  end

  def handle_event("prev_page", _params, %{assigns: %{page: page}} = socket) when page > 1 do
    {:noreply, socket |> assign(:page, page - 1) |> trigger_search()}
  end

  def handle_event("prev_page", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:execute_search, query}, socket) do
    socket = assign(socket, :query, query)
    {:noreply, perform_search(socket)}
  end

  def handle_info(:search_complete, socket) do
    {:noreply, socket}
  end

  defp trigger_search(socket) do
    cancel_pending_search(socket.assigns.search_timer)
    perform_search(socket)
  end

  defp perform_search(socket) do
    %{query: query, filters: filters, page: page} = socket.assigns

    search_opts = [
      page: page,
      page_size: @page_size,
      filters: filters
    ]

    case Products.search(query, search_opts) do
      {:ok, %{results: results, total: total}} ->
        socket
        |> assign(:results, results)
        |> assign(:total_count, total)
        |> assign(:loading, false)

      {:error, _reason} ->
        socket
        |> assign(:results, [])
        |> assign(:total_count, 0)
        |> assign(:loading, false)
    end
  end

  defp cancel_pending_search(nil), do: :ok
  defp cancel_pending_search(timer_ref), do: Process.cancel_timer(timer_ref)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="product-search">
      <input
        type="text"
        value={@query}
        phx-input="search_input"
        placeholder="Search products..."
      />
      <%= if @loading do %>
        <div class="loading-indicator">Searching...</div>
      <% else %>
        <p class="result-count"><%= @total_count %> results</p>
        <ul>
          <%= for product <- @results do %>
            <li><%= product.name %> — <%= product.sku %></li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end
end
```
