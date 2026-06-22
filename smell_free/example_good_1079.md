```elixir
defmodule Telemetry.MetricsAggregator do
  @moduledoc """
  A supervised GenServer that accumulates time-series metric events and
  flushes aggregated summaries to a backend store on a configurable interval.
  """

  use GenServer

  alias Telemetry.{Backend, MetricsBucket}

  @flush_interval_ms 10_000

  @type metric_event :: %{name: String.t(), value: number(), tags: map()}
  @type state :: %{bucket: MetricsBucket.t(), flush_interval: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(metric_event()) :: :ok
  def record(event) do
    GenServer.cast(__MODULE__, {:record, event})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    schedule_flush(interval)
    {:ok, %{bucket: MetricsBucket.new(), flush_interval: interval}}
  end

  @impl GenServer
  def handle_cast({:record, event}, state) do
    updated_bucket = MetricsBucket.insert(state.bucket, event)
    {:noreply, %{state | bucket: updated_bucket}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    :ok = persist_and_reset(state)
    {:reply, :ok, %{state | bucket: MetricsBucket.new()}}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    :ok = persist_and_reset(state)
    schedule_flush(state.flush_interval)
    {:noreply, %{state | bucket: MetricsBucket.new()}}
  end

  @spec persist_and_reset(state()) :: :ok
  defp persist_and_reset(state) do
    summaries = MetricsBucket.summarize(state.bucket)
    Backend.write_batch(summaries)
  end

  @spec schedule_flush(pos_integer()) :: reference()
  defp schedule_flush(interval) do
    Process.send_after(self(), :scheduled_flush, interval)
  end
end

defmodule Telemetry.MetricsBucket do
  @moduledoc """
  An immutable data structure for accumulating raw metric events
  and computing per-name statistical summaries.
  """

  @type t :: %{String.t() => [number()]}

  @spec new() :: t()
  def new, do: %{}

  @spec insert(t(), map()) :: t()
  def insert(bucket, %{name: name, value: value}) do
    Map.update(bucket, name, [value], &[value | &1])
  end

  @spec summarize(t()) :: [map()]
  def summarize(bucket) do
    Enum.map(bucket, fn {name, values} ->
      count = length(values)
      total = Enum.sum(values)

      %{
        name: name,
        count: count,
        sum: total,
        avg: total / count,
        min: Enum.min(values),
        max: Enum.max(values)
      }
    end)
  end
end
```
