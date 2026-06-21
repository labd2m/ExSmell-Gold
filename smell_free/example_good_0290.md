```elixir
defmodule MyApp.Realtime.LiveDashboard do
  @moduledoc """
  A Phoenix LiveView that renders a real-time operations dashboard.
  Metric snapshots are pushed every few seconds via `Process.send_after/3`
  and subscription to domain events is handled through PubSub so the view
  always reflects current system state without polling HTTP endpoints.

  Component state is kept minimal: only the data needed to render the
  current frame is held in assigns; derived values are computed in the
  template rather than stored.
  """

  use Phoenix.LiveView

  alias MyApp.Analytics.SessionAggregator
  alias MyApp.VideoEncoder.Pool, as: EncoderPool
  alias MyApp.Cache
  alias MyApp.Events

  @refresh_interval_ms 3_000
  @topic "ops:dashboard"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
      schedule_refresh()
    end

    {:ok, assign(socket, initial_assigns())}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, fetch_metrics())}
  end

  @impl Phoenix.LiveView
  def handle_info({:domain_event, %Events.OrderPlaced{} = event}, socket) do
    updated =
      socket.assigns.recent_orders
      |> prepend_and_trim(format_order_event(event), 10)

    {:noreply, assign(socket, :recent_orders, updated)}
  end

  @impl Phoenix.LiveView
  def handle_info({:domain_event, _event}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("set_window", %{"hours" => hours_str}, socket) do
    case Integer.parse(hours_str) do
      {hours, ""} when hours in 1..24 ->
        {:noreply, assign(socket, :session_window_hours, hours)}

      _ ->
        {:noreply, socket}
    end
  end

  @spec initial_assigns() :: keyword()
  defp initial_assigns do
    [
      metrics: fetch_metrics(),
      recent_orders: [],
      session_window_hours: 1
    ]
  end

  @spec fetch_metrics() :: keyword()
  defp fetch_metrics do
    session_summary = SessionAggregator.summary(1)

    [
      active_encoders: EncoderPool.active_count(),
      cache_size: Cache.size(),
      unique_sessions_1h: session_summary.unique_sessions,
      page_views_1h: session_summary.page_views,
      fetched_at: DateTime.utc_now()
    ]
  end

  @spec format_order_event(Events.OrderPlaced.t()) :: map()
  defp format_order_event(event) do
    %{
      order_id: event.order_id,
      total_cents: event.total_cents,
      occurred_at: event.occurred_at
    }
  end

  @spec prepend_and_trim(list(), term(), pos_integer()) :: list()
  defp prepend_and_trim(list, item, max) do
    [item | list] |> Enum.take(max)
  end

  @spec schedule_refresh() :: reference()
  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)
end
```
