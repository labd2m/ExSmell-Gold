```elixir
defmodule Observability.MetricsCollector do
  @moduledoc """
  A GenServer that attaches to Telemetry events and maintains in-memory
  aggregate metrics for counters, gauges, and histograms.

  Designed to be started under a supervision tree and queried or flushed
  at any time via the public API.
  """

  use GenServer

  require Logger

  @type metric_type :: :counter | :gauge | :histogram
  @type counter :: %{type: :counter, count: non_neg_integer()}
  @type gauge :: %{type: :gauge, value: number(), updated_at: DateTime.t()}
  @type histogram :: %{type: :histogram, count: non_neg_integer(), sum: number(), values: [number()]}
  @type metric :: counter() | gauge() | histogram()
  @type metrics_map :: %{optional([atom()]) => metric()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Attaches the collector to the given Telemetry event name list.
  Returns `:ok` or an attachment error.
  """
  @spec attach([[atom()]]) :: :ok | {:error, :already_exists}
  def attach(event_names) when is_list(event_names) do
    :telemetry.attach_many("metrics_collector", event_names, &handle_telemetry/4, nil)
  end

  @doc "Returns a snapshot of all accumulated metrics without clearing them."
  @spec snapshot() :: metrics_map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Clears all accumulated metrics and returns the final snapshot."
  @spec flush() :: metrics_map()
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(_opts) do
    {:ok, %{metrics: %{}}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state.metrics, state}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, state.metrics, %{state | metrics: %{}}}
  end

  @impl GenServer
  def handle_cast({:record, event_name, measurements}, state) do
    updated =
      Map.update(
        state.metrics,
        event_name,
        init_metric(measurements),
        &merge_metric(&1, measurements)
      )

    {:noreply, %{state | metrics: updated}}
  end

  defp handle_telemetry(event_name, measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:record, event_name, measurements})
  end

  defp init_metric(%{duration: d}), do: %{type: :histogram, count: 1, sum: d, values: [d]}
  defp init_metric(%{count: c}), do: %{type: :counter, count: c}
  defp init_metric(%{value: v}), do: %{type: :gauge, value: v, updated_at: DateTime.utc_now()}
  defp init_metric(_), do: %{type: :counter, count: 1}

  defp merge_metric(%{type: :histogram} = m, %{duration: d}) do
    %{m | count: m.count + 1, sum: m.sum + d, values: [d | m.values]}
  end

  defp merge_metric(%{type: :counter} = m, %{count: inc}) do
    %{m | count: m.count + inc}
  end

  defp merge_metric(%{type: :gauge}, %{value: v}) do
    %{type: :gauge, value: v, updated_at: DateTime.utc_now()}
  end

  defp merge_metric(existing, _), do: existing
end
```
