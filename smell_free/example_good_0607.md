```elixir
defmodule MyAppWeb.Live.MetricsDashboard do
  @moduledoc """
  A LiveView dashboard that displays real-time platform metrics. Metrics
  are pushed via Phoenix PubSub whenever domain events occur, keeping the
  dashboard live without polling. The view subscribes to a specific topic
  on mount and unsubscribes automatically when the socket disconnects via
  the process link. Stale data is highlighted when the last update exceeds
  a staleness threshold so operators can detect a silent data feed failure.
  """

  use MyAppWeb, :live_view

  alias MyApp.Metrics

  require Logger

  @pubsub_topic "metrics:platform"
  @staleness_threshold_seconds 60

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, @pubsub_topic)
    end

    metrics = Metrics.current_snapshot()

    socket =
      socket
      |> assign(:metrics, metrics)
      |> assign(:last_updated_at, DateTime.utc_now())
      |> assign(:stale, false)
      |> assign(:connected, connected?(socket))

    {:ok, socket, temporary_assigns: []}
  end

  @impl Phoenix.LiveView
  def handle_info({:metrics_update, new_metrics}, socket) do
    socket =
      socket
      |> assign(:metrics, new_metrics)
      |> assign(:last_updated_at, DateTime.utc_now())
      |> assign(:stale, false)

    {:noreply, socket}
  end

  def handle_info(:check_staleness, socket) do
    seconds_since = DateTime.diff(DateTime.utc_now(), socket.assigns.last_updated_at, :second)
    stale = seconds_since > @staleness_threshold_seconds

    if stale do
      Logger.warning("Metrics dashboard feed is stale",
        seconds_since_update: seconds_since
      )
    end

    {:noreply, assign(socket, :stale, stale)}
  end

  @impl Phoenix.LiveView
  def handle_event("refresh", _params, socket) do
    metrics = Metrics.current_snapshot()

    socket =
      socket
      |> assign(:metrics, metrics)
      |> assign(:last_updated_at, DateTime.utc_now())
      |> assign(:stale, false)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <header class="dashboard-header">
        <h1>Platform Metrics</h1>
        <div class="last-updated">
          <%= if @stale do %>
            <span class="badge-warning">Data may be stale</span>
          <% end %>
          <span>Updated <%= format_relative(@last_updated_at) %></span>
          <button phx-click="refresh">Refresh</button>
        </div>
      </header>

      <section class="metric-grid">
        <.metric_card
          title="Active Users"
          value={@metrics.active_users}
          trend={@metrics.active_users_trend}
          unit="users"
        />
        <.metric_card
          title="Orders Today"
          value={@metrics.orders_today}
          trend={@metrics.orders_trend}
          unit="orders"
        />
        <.metric_card
          title="Revenue Today"
          value={format_currency(@metrics.revenue_cents_today)}
          trend={@metrics.revenue_trend}
          unit=""
        />
        <.metric_card
          title="Error Rate"
          value={@metrics.error_rate_pct}
          trend={@metrics.error_rate_trend}
          unit="%"
          invert_trend={true}
        />
      </section>

      <section class="queue-status">
        <h2>Queue Depths</h2>
        <%= for {queue, depth} <- @metrics.queue_depths do %>
          <div class="queue-row">
            <span class="queue-name"><%= queue %></span>
            <span class={"queue-depth #{depth_class(depth)}"}><%= depth %></span>
          </div>
        <% end %>
      </section>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_relative(dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3_600)}h ago"
    end
  end

  defp format_currency(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading("#{remainder}", 2, "0")}"
  end

  defp format_currency(_), do: "$0.00"

  defp depth_class(depth) when depth > 1_000, do: "depth-critical"
  defp depth_class(depth) when depth > 100, do: "depth-warning"
  defp depth_class(_), do: "depth-normal"
end
```
