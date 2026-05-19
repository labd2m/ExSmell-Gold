# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Metrics.Aggregator.push_window_to_exporter/2` |
| **Affected function(s)** | `push_window_to_exporter/2` |
| **Short explanation** | The aggregator retrieves a full metrics window—hundreds of thousands of individual time-series data points across many metric names—and sends the entire window map as a single process message to the Prometheus exporter process. The message is very large and blocks the aggregator. |

```elixir
defmodule Metrics.DataPoint do
  @enforce_keys [:value, :timestamp, :labels]
  defstruct [:value, :timestamp, :labels, :exemplar]

  @type t :: %__MODULE__{
          value: float(),
          timestamp: integer(),
          labels: %{String.t() => String.t()},
          exemplar: map() | nil
        }
end

defmodule Metrics.MetricSeries do
  @enforce_keys [:name, :type, :description, :points]
  defstruct [:name, :type, :description, :unit, :points, :help_text]

  @type t :: %__MODULE__{
          name: String.t(),
          type: :counter | :gauge | :histogram | :summary,
          description: String.t(),
          unit: String.t() | nil,
          points: [Metrics.DataPoint.t()],
          help_text: String.t()
        }
end

defmodule Metrics.Window do
  @enforce_keys [:id, :starts_at, :ends_at, :series]
  defstruct [:id, :starts_at, :ends_at, :series, :scrape_interval_ms, :source_node]

  @type t :: %__MODULE__{
          id: String.t(),
          starts_at: integer(),
          ends_at: integer(),
          series: %{String.t() => Metrics.MetricSeries.t()},
          scrape_interval_ms: pos_integer(),
          source_node: String.t()
        }
end

defmodule Metrics.WindowStore do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get_current_window, do: GenServer.call(__MODULE__, :get_current, 30_000)

  @impl true
  def init(_), do: {:ok, build_window()}

  @impl true
  def handle_call(:get_current, _from, window) do
    {:reply, window, window}
  end

  defp build_window do
    now_ms = System.system_time(:millisecond)

    metric_names = [
      "http_request_duration_seconds",
      "http_requests_total",
      "db_query_duration_seconds",
      "db_connections_active",
      "cache_hit_rate",
      "cache_miss_total",
      "worker_queue_depth",
      "memory_usage_bytes",
      "cpu_usage_percent",
      "gc_runs_total",
      "process_count",
      "socket_connections_active",
      "pubsub_messages_sent_total",
      "pubsub_messages_received_total",
      "job_queue_latency_seconds"
    ]

    series =
      Map.new(metric_names, fn name ->
        points =
          Enum.map(1..5_000, fn i ->
            %Metrics.DataPoint{
              value: :rand.uniform() * 1_000,
              timestamp: now_ms - i * 1_000,
              labels: %{
                "instance" => "node-#{rem(i, 10) + 1}",
                "env" => "production",
                "region" => Enum.random(["us-east-1", "eu-west-1", "ap-south-1"]),
                "handler" => "/api/v#{rem(i, 3) + 1}/endpoint_#{rem(i, 50) + 1}",
                "status" => Enum.random(["200", "201", "400", "404", "500"])
              },
              exemplar:
                if rem(i, 100) == 0 do
                  %{trace_id: "trace_#{i}", span_id: "span_#{i}", value: :rand.uniform()}
                end
            }
          end)

        series = %Metrics.MetricSeries{
          name: name,
          type: Enum.random([:counter, :gauge, :histogram]),
          description: "#{name} tracks system-level operational metrics",
          unit: Enum.random(["seconds", "bytes", "requests", nil]),
          help_text: "# HELP #{name} Tracks #{name} across all instances.",
          points: points
        }

        {name, series}
      end)

    %Metrics.Window{
      id: "win_#{System.unique_integer([:positive])}",
      starts_at: now_ms - 300_000,
      ends_at: now_ms,
      series: series,
      scrape_interval_ms: 1_000,
      source_node: "node@host.example.com"
    }
  end
end

defmodule Metrics.ExporterWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:export_window, window}, _state) do
    {:noreply, window}
  end
end

defmodule Metrics.Aggregator do
  @moduledoc """
  Periodically fetches the current metrics window and sends it to
  the Prometheus exporter worker for formatting and exposure.
  """

  require Logger

  @spec push_window_to_exporter(pid(), String.t()) :: :ok
  def push_window_to_exporter(exporter_pid, node_id) do
    Logger.info("Fetching current metrics window for node #{node_id}...")

    window = Metrics.WindowStore.get_current_window()

    total_points =
      Enum.reduce(window.series, 0, fn {_, series}, acc -> acc + length(series.points) end)

    Logger.info(
      "Window #{window.id} contains #{map_size(window.series)} series, " <>
        "#{total_points} data points total. Sending to exporter..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `window` contains 15 MetricSeries,
    # each with 5,000 DataPoint structs (75,000 points total). Each DataPoint
    # has a 5-key labels map and an optional exemplar. Sending this entire
    # nested map structure as one process message forces a large deep-copy
    # across heap boundaries, blocking the Aggregator and causing it to miss
    # subsequent scrape cycles.
    send(exporter_pid, {:export_window, window})
    # VALIDATION: SMELL END

    Logger.info("Metrics window dispatched to exporter.")
    :ok
  end
end
```
