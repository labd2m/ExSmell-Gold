```elixir
defmodule Telemetry.MetricsAggregator do
  @moduledoc """
  Collects numeric measurements emitted via `:telemetry` events and
  computes rolling window statistics. A periodic flush logs the summary
  and resets counters for the next window.
  """

  use GenServer

  require Logger

  @flush_interval_ms 60_000

  @type event_name :: list(atom())
  @type histogram :: list(number())
  @type stats :: %{count: non_neg_integer(), min: number(), max: number(), avg: float()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec attach(list(event_name())) :: :ok
  def attach(event_names) when is_list(event_names) do
    Enum.each(event_names, fn name ->
      :telemetry.attach(
        handler_id(name),
        name,
        &__MODULE__.handle_event/4,
        nil
      )
    end)
  end

  @spec detach(list(event_name())) :: :ok
  def detach(event_names) when is_list(event_names) do
    Enum.each(event_names, fn name -> :telemetry.detach(handler_id(name)) end)
  end

  @spec summary() :: %{String.t() => stats()}
  def summary do
    GenServer.call(__MODULE__, :summary)
  end

  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @doc false
  def handle_event(event_name, measurements, _meta, _cfg) do
    GenServer.cast(__MODULE__, {:record, event_name, measurements})
  end

  @impl GenServer
  def init(_opts) do
    schedule_flush()
    {:ok, fresh_state()}
  end

  @impl GenServer
  def handle_cast({:record, event_name, measurements}, state) do
    key_prefix = Enum.join(event_name, ".")

    updated =
      Enum.reduce(measurements, state, fn {metric, value}, acc ->
        key = "#{key_prefix}.#{metric}"
        Map.update(acc, key, [value], &[value | &1])
      end)

    {:noreply, updated}
  end

  def handle_cast(:reset, _state) do
    schedule_flush()
    {:noreply, fresh_state()}
  end

  @impl GenServer
  def handle_call(:summary, _from, state) do
    stats = Map.new(state, fn {k, values} -> {k, compute_stats(values)} end)
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    stats = Map.new(state, fn {k, values} -> {k, compute_stats(values)} end)
    Logger.info("Telemetry window flush", window_stats: inspect(stats))
    schedule_flush()
    {:noreply, fresh_state()}
  end

  defp compute_stats([]), do: %{count: 0, min: nil, max: nil, avg: nil}

  defp compute_stats(values) do
    count = length(values)
    %{count: count, min: Enum.min(values), max: Enum.max(values), avg: Enum.sum(values) / count}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp handler_id(event_name) do
    "metrics_aggregator.#{Enum.join(event_name, ".")}"
  end

  defp fresh_state, do: %{}
end
```
