```elixir
defmodule Telemetry.Label do
  defstruct [:service, :host, :region, :environment, :version, :instance_id]
end

defmodule Telemetry.DataPoint do
  @enforce_keys [:name, :value, :timestamp, :labels]
  defstruct [:name, :value, :unit, :type, :timestamp, :labels, :exemplar]
end

defmodule Telemetry.MetricSeries do
  @enforce_keys [:metric_id, :data_points]
  defstruct [:metric_id, :data_points, :resolution_seconds, :retention_policy, :description]
end

defmodule Telemetry.InMemoryBuffer do
  @moduledoc "Simulates an in-process metrics accumulation buffer."

  @spec drain() :: list(Telemetry.MetricSeries.t())
  def drain do
    Enum.map(1..2_000, fn series_i ->
      %Telemetry.MetricSeries{
        metric_id: "metric_#{series_i}",
        data_points: Enum.map(1..200, fn dp_i ->
          %Telemetry.DataPoint{
            name: "app.#{Enum.random(["cpu", "mem", "req_rate", "error_rate", "latency"])}",
            value: :rand.uniform() * 100,
            unit: Enum.random(["percent", "bytes", "ms", "req/s"]),
            type: Enum.random([:gauge, :counter, :histogram]),
            timestamp: System.system_time(:millisecond) - dp_i * 1_000,
            labels: %Telemetry.Label{
              service: "svc-#{rem(series_i, 20)}",
              host: "host-#{rem(dp_i, 50)}",
              region: Enum.random(["us-east-1", "eu-west-1", "sa-east-1"]),
              environment: "production",
              version: "1.#{rem(series_i, 10)}.#{rem(dp_i, 20)}",
              instance_id: "i-#{series_i}#{dp_i}"
            },
            exemplar: if(rem(dp_i, 20) == 0,
              do: %{trace_id: "trace-#{dp_i}", span_id: "span-#{dp_i}"},
              else: nil
            )
          }
        end),
        resolution_seconds: 10,
        retention_policy: "30d",
        description: "Auto-collected series #{series_i}"
      }
    end)
  end
end

defmodule Telemetry.MetricsStore do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{series: %{}, flush_count: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:ingest, series_list}, state) do
    updated_series =
      Enum.reduce(series_list, state.series, fn s, acc ->
        Map.put(acc, s.metric_id, s)
      end)

    {:noreply, %{state | series: updated_series, flush_count: state.flush_count + 1}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{series_count: map_size(state.series), flushes: state.flush_count}, state}
  end
end

defmodule Telemetry.MetricsFlusher do
  @moduledoc "Periodically drains the in-memory buffer and persists metrics to the store."

  require Logger

  @spec flush_to_store(pid()) :: :ok
  def flush_to_store(store_pid) do
    series_list = Telemetry.InMemoryBuffer.drain()
    total_points = Enum.sum(Enum.map(series_list, fn s -> length(s.data_points) end))

    Logger.info("Flushing #{length(series_list)} series / #{total_points} points to metrics store")

    GenServer.cast(store_pid, {:ingest, series_list})

    :ok
  end

  @spec start_flush_loop(pid(), non_neg_integer()) :: :ok
  def start_flush_loop(store_pid, interval_ms \\ 10_000) do
    Stream.interval(interval_ms)
    |> Stream.each(fn _ -> flush_to_store(store_pid) end)
    |> Stream.run()
  end
end
```
