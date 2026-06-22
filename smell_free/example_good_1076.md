**File:** `example_good_1076.md`

```elixir
defmodule Telemetry.Pipeline do
  @moduledoc """
  Metrics collection pipeline with a full OTP supervision tree.
  The pipeline ingests events from a buffer, aggregates them over
  configurable time windows, and flushes summaries to a backend sink.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Telemetry.Registry},
      Telemetry.Buffer,
      Telemetry.Aggregator,
      {Task.Supervisor, name: Telemetry.FlushSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Telemetry.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule Telemetry.Buffer do
  @moduledoc """
  Bounded in-process event buffer. Producers write metrics asynchronously.
  When the buffer reaches its high-water mark, the oldest entries are dropped
  to maintain bounded memory usage.
  """

  use GenServer

  @max_size 10_000

  @type metric :: %{name: String.t(), value: number(), tags: map(), timestamp: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    max_size = Keyword.get(opts, :max_size, @max_size)
    GenServer.start_link(__MODULE__, max_size, name: __MODULE__)
  end

  @spec push(metric()) :: :ok
  def push(%{name: _, value: _, tags: _, timestamp: _} = metric) do
    GenServer.cast(__MODULE__, {:push, metric})
  end

  @spec drain(pos_integer()) :: [metric()]
  def drain(count) when is_integer(count) and count > 0 do
    GenServer.call(__MODULE__, {:drain, count})
  end

  @spec size() :: non_neg_integer()
  def size, do: GenServer.call(__MODULE__, :size)

  @impl GenServer
  def init(max_size) do
    {:ok, %{queue: :queue.new(), size: 0, max_size: max_size}}
  end

  @impl GenServer
  def handle_cast({:push, metric}, %{size: size, max_size: max} = state) when size >= max do
    {_, trimmed_queue} = :queue.out(state.queue)
    new_queue = :queue.in(metric, trimmed_queue)
    {:noreply, %{state | queue: new_queue}}
  end

  def handle_cast({:push, metric}, state) do
    new_queue = :queue.in(metric, state.queue)
    {:noreply, %{state | queue: new_queue, size: state.size + 1}}
  end

  @impl GenServer
  def handle_call({:drain, count}, _from, state) do
    {items, remaining_queue, remaining_size} = pop_n(state.queue, state.size, count, [])
    {:reply, items, %{state | queue: remaining_queue, size: remaining_size}}
  end

  def handle_call(:size, _from, state) do
    {:reply, state.size, state}
  end

  defp pop_n(queue, size, 0, acc), do: {Enum.reverse(acc), queue, size}
  defp pop_n(queue, 0, _n, acc), do: {Enum.reverse(acc), queue, 0}

  defp pop_n(queue, size, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> pop_n(rest, size - 1, n - 1, [item | acc])
      {:empty, _} -> {Enum.reverse(acc), queue, 0}
    end
  end
end

defmodule Telemetry.Aggregator do
  @moduledoc """
  Periodically drains the buffer, aggregates metrics by name and tags
  using sum and average, then dispatches summaries to the sink backend.
  """

  use GenServer

  alias Telemetry.{Buffer, Sink}

  @flush_interval_ms 5_000
  @batch_size 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_flush()
    {:ok, %{flush_count: 0}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    metrics = Buffer.drain(@batch_size)

    unless metrics == [] do
      summaries = aggregate(metrics)
      Task.Supervisor.start_child(Telemetry.FlushSupervisor, fn -> Sink.write(summaries) end)
    end

    schedule_flush()
    {:noreply, %{state | flush_count: state.flush_count + 1}}
  end

  defp aggregate(metrics) do
    metrics
    |> Enum.group_by(&group_key/1)
    |> Enum.map(&build_summary/1)
  end

  defp group_key(%{name: name, tags: tags}) do
    sorted_tags = tags |> Enum.sort() |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(",")
    "#{name}|#{sorted_tags}"
  end

  defp build_summary({_key, [%{name: name, tags: tags} | _] = group}) do
    values = Enum.map(group, & &1.value)
    count = length(values)
    total = Enum.sum(values)

    %{
      name: name,
      tags: tags,
      count: count,
      sum: total,
      avg: total / count,
      min: Enum.min(values),
      max: Enum.max(values),
      window_end: System.system_time(:millisecond)
    }
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```
