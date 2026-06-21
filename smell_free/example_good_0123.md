```elixir
defmodule MyApp.Telemetry.MetricsReporter do
  @moduledoc """
  A GenServer that aggregates `:telemetry` events emitted by the application
  and periodically flushes counter and timing summaries to `StatsD` via
  `Statix`. Each event handler is attached once during `init/1` and detached
  cleanly during termination, preventing duplicate registrations across hot
  reloads.

  Place this module in the application supervision tree:

      children = [{MyApp.Telemetry.MetricsReporter, flush_interval_ms: 10_000}]
  """

  use GenServer

  require Logger

  @default_flush_ms 10_000
  @handler_id :my_app_metrics_reporter

  @tracked_events [
    {[:my_app, :http, :request, :stop], :http_request},
    {[:my_app, :repo, :query], :db_query},
    {[:my_app, :cache, :hit], :cache_hit},
    {[:my_app, :cache, :miss], :cache_miss}
  ]

  @type bucket :: %{count: non_neg_integer(), total_ms: non_neg_integer()}
  @type state :: %{
          buckets: %{atom() => bucket()},
          flush_interval_ms: pos_integer()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    attach_handlers()
    interval = Keyword.get(opts, :flush_interval_ms, @default_flush_ms)
    schedule_flush(interval)

    {:ok, %{buckets: %{}, flush_interval_ms: interval}}
  end

  @impl GenServer
  def handle_cast({:record, metric, duration_ms}, state) do
    updated = update_bucket(state.buckets, metric, duration_ms)
    {:noreply, %{state | buckets: updated}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    flush_buckets(state.buckets)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buckets: %{}}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
  end

  @spec attach_handlers() :: :ok
  defp attach_handlers do
    events = Enum.map(@tracked_events, &elem(&1, 0))
    lookup = Map.new(@tracked_events)

    :telemetry.attach_many(
      @handler_id,
      events,
      fn event_name, measurements, _meta, _cfg ->
        metric = Map.fetch!(lookup, event_name)
        duration = Map.get(measurements, :duration_ms, 0)
        GenServer.cast(__MODULE__, {:record, metric, duration})
      end,
      nil
    )
  end

  @spec update_bucket(%{atom() => bucket()}, atom(), non_neg_integer()) ::
          %{atom() => bucket()}
  defp update_bucket(buckets, metric, duration_ms) do
    Map.update(
      buckets,
      metric,
      %{count: 1, total_ms: duration_ms},
      fn b -> %{count: b.count + 1, total_ms: b.total_ms + duration_ms} end
    )
  end

  @spec flush_buckets(%{atom() => bucket()}) :: :ok
  defp flush_buckets(buckets) do
    Enum.each(buckets, fn {metric, bucket} ->
      Statix.increment("#{metric}.count", bucket.count)

      if bucket.count > 0 do
        avg = div(bucket.total_ms, bucket.count)
        Statix.gauge("#{metric}.avg_ms", avg)
      end
    end)
  end

  @spec schedule_flush(pos_integer()) :: reference()
  defp schedule_flush(interval_ms),
    do: Process.send_after(self(), :flush, interval_ms)
end
```
