# File: `example_good_13.md`

```elixir
defmodule Telemetry.MetricsReporter do
  @moduledoc """
  Attaches telemetry handlers that aggregate application metrics and
  forward them to a configured reporter backend on a flush interval.

  Metric state is held inside a GenServer. Handlers are registered during
  `start_link/1` and detached cleanly on process termination.
  """

  use GenServer

  require Logger

  @flush_interval_ms 10_000

  @type metric_name :: [atom()]
  @type measurement :: number()
  @type backend :: module()

  @type opts :: [
          metrics: [metric_name()],
          backend: backend(),
          flush_interval_ms: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    metrics = Keyword.fetch!(opts, :metrics)
    backend = Keyword.fetch!(opts, :backend)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)

    handler_ids = attach_handlers(metrics)
    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       handler_ids: handler_ids,
       backend: backend,
       flush_interval_ms: flush_interval_ms,
       counters: %{},
       histograms: %{}
     }}
  end

  @impl GenServer
  def handle_info({:telemetry_event, event_name, measurements}, state) do
    new_state = record_measurements(state, event_name, measurements)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    flush_to_backend(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | counters: %{}, histograms: %{}}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
    :ok
  end

  defp attach_handlers(metrics) do
    Enum.map(metrics, fn event_name ->
      handler_id = handler_id_for(event_name)

      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.handle_telemetry_event/4,
        nil
      )

      handler_id
    end)
  end

  @doc false
  def handle_telemetry_event(event_name, measurements, _metadata, _config) do
    send(__MODULE__, {:telemetry_event, event_name, measurements})
  end

  defp record_measurements(state, event_name, measurements) do
    state
    |> record_counters(event_name, measurements)
    |> record_histograms(event_name, measurements)
  end

  defp record_counters(state, event_name, %{count: count}) when is_number(count) do
    key = event_name
    updated = Map.update(state.counters, key, count, &(&1 + count))
    %{state | counters: updated}
  end

  defp record_counters(state, _event_name, _measurements), do: state

  defp record_histograms(state, event_name, %{duration: duration}) when is_number(duration) do
    key = event_name
    bucket = Map.get(state.histograms, key, [])
    updated = Map.put(state.histograms, key, [duration | bucket])
    %{state | histograms: updated}
  end

  defp record_histograms(state, _event_name, _measurements), do: state

  defp flush_to_backend(state) do
    summary = build_summary(state)

    case state.backend.report(summary) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Metrics flush failed: #{inspect(reason)}")
    end
  end

  defp build_summary(state) do
    histogram_stats =
      Map.new(state.histograms, fn {key, values} ->
        {key, compute_histogram_stats(values)}
      end)

    %{counters: state.counters, histograms: histogram_stats}
  end

  defp compute_histogram_stats([]), do: %{count: 0, min: nil, max: nil, mean: nil}

  defp compute_histogram_stats(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    %{
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Enum.sum(sorted) / count
    }
  end

  defp handler_id_for(event_name) do
    "#{__MODULE__}:#{Enum.join(event_name, ".")}"
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :flush, interval_ms)
  end
end
```
