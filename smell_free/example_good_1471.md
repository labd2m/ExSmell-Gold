```elixir
defmodule Metrics.Measurement do
  @moduledoc """
  A single time-stamped metric observation with optional dimensional labels.
  """

  @type t :: %__MODULE__{
          name: atom(),
          value: number(),
          labels: map(),
          recorded_at: integer()
        }

  defstruct [:name, :value, :recorded_at, labels: %{}]
end

defmodule Metrics.Aggregator do
  use GenServer

  alias Metrics.Measurement

  @moduledoc """
  Buffers incoming metric measurements and provides windowed summaries.
  Automatically flushes the buffer to a configurable reporter every interval.
  """

  @flush_interval_ms 15_000

  @type summary :: %{
          name: atom(),
          count: non_neg_integer(),
          sum: number(),
          min: number(),
          max: number(),
          avg: float()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(atom(), number(), map()) :: :ok
  def record(name, value, labels \\ %{})
      when is_atom(name) and is_number(value) and is_map(labels) do
    measurement = %Measurement{
      name: name,
      value: value,
      labels: labels,
      recorded_at: System.monotonic_time(:millisecond)
    }

    GenServer.cast(__MODULE__, {:record, measurement})
  end

  @spec flush() :: [summary()]
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    reporter = Keyword.get(opts, :reporter, Metrics.LogReporter)
    schedule_flush()
    {:ok, %{buffer: [], reporter: reporter}}
  end

  @impl GenServer
  def handle_cast({:record, measurement}, state) do
    {:noreply, %{state | buffer: [measurement | state.buffer]}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    summaries = summarize(state.buffer)
    {:reply, summaries, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    summaries = summarize(state.buffer)
    state.reporter.report(summaries)
    schedule_flush()
    {:noreply, %{state | buffer: []}}
  end

  defp summarize([]), do: []

  defp summarize(measurements) do
    measurements
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, group} -> build_summary(name, group) end)
  end

  defp build_summary(name, measurements) do
    values = Enum.map(measurements, & &1.value)
    count = length(values)
    sum = Enum.sum(values)

    %{
      name: name,
      count: count,
      sum: sum,
      min: Enum.min(values),
      max: Enum.max(values),
      avg: sum / count
    }
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end

defmodule Metrics.LogReporter do
  require Logger

  @moduledoc "Reports metric summaries to the application logger."

  @spec report([Metrics.Aggregator.summary()]) :: :ok
  def report(summaries) when is_list(summaries) do
    Enum.each(summaries, fn s ->
      Logger.info("[metric] #{s.name} count=#{s.count} avg=#{Float.round(s.avg, 4)} min=#{s.min} max=#{s.max}")
    end)
  end
end
```
