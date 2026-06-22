```elixir
defmodule Devices.TelemetryCollector do
  @moduledoc """
  GenServer that collects and buffers telemetry readings from IoT devices.

  Readings are accumulated in-process and periodically summarized into
  per-device statistics (min, max, mean) before being dispatched to the
  configured sink. The collection window and dispatch interval are
  configurable at startup.
  """

  use GenServer

  require Logger

  alias Devices.ReadingSink
  alias Devices.ReadingSummary

  @default_window_ms 60_000

  @type device_id :: String.t()
  @type metric :: String.t()
  @type reading :: %{device_id: device_id(), metric: metric(), value: float(), ts: DateTime.t()}
  @type buffer :: %{device_id() => %{metric() => [float()]}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Ingests a single telemetry reading into the buffer."
  @spec ingest(reading()) :: :ok
  def ingest(%{device_id: _, metric: _, value: _, ts: _} = reading) do
    GenServer.cast(__MODULE__, {:ingest, reading})
  end

  @doc "Returns a snapshot of the current buffer without flushing."
  @spec buffer_snapshot() :: buffer()
  def buffer_snapshot do
    GenServer.call(__MODULE__, :buffer_snapshot)
  end

  @impl GenServer
  def init(opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    schedule_dispatch(window_ms)
    {:ok, %{buffer: %{}, window_ms: window_ms}}
  end

  @impl GenServer
  def handle_cast({:ingest, %{device_id: device_id, metric: metric, value: value}}, state) do
    updated_buffer =
      Map.update(state.buffer, device_id, %{metric => [value]}, fn device_metrics ->
        Map.update(device_metrics, metric, [value], &[value | &1])
      end)

    {:noreply, %{state | buffer: updated_buffer}}
  end

  @impl GenServer
  def handle_call(:buffer_snapshot, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl GenServer
  def handle_info(:dispatch, state) do
    summaries = summarize(state.buffer)
    dispatch_summaries(summaries)
    schedule_dispatch(state.window_ms)
    {:noreply, %{state | buffer: %{}}}
  end

  @spec summarize(buffer()) :: [ReadingSummary.t()]
  defp summarize(buffer) do
    for {device_id, metrics} <- buffer,
        {metric, values} <- metrics,
        values != [] do
      sorted = Enum.sort(values)
      count = length(sorted)

      %ReadingSummary{
        device_id: device_id,
        metric: metric,
        min: List.first(sorted),
        max: List.last(sorted),
        mean: Float.round(Enum.sum(sorted) / count, 4),
        sample_count: count,
        summarized_at: DateTime.utc_now()
      }
    end
  end

  @spec dispatch_summaries([ReadingSummary.t()]) :: :ok
  defp dispatch_summaries([]), do: :ok

  defp dispatch_summaries(summaries) do
    case ReadingSink.write_batch(summaries) do
      :ok ->
        Logger.debug("Dispatched #{length(summaries)} reading summaries.")

      {:error, reason} ->
        Logger.error("Failed to dispatch summaries: #{inspect(reason)}")
    end
  end

  @spec schedule_dispatch(pos_integer()) :: reference()
  defp schedule_dispatch(window_ms) do
    Process.send_after(self(), :dispatch, window_ms)
  end
end
```
