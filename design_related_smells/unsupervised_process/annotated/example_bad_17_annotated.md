# Annotated Example 17 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Telemetry.DeviceCollector.connect/2`
- **Affected function(s):** `connect/2`
- **Short explanation:** Each IoT device gets its own telemetry collector GenServer spawned via `GenServer.start/3` outside a supervision tree. In a fleet of thousands of devices, these unsupervised processes proliferate uncontrollably, and any crash silently stops data collection for that device.

```elixir
defmodule Telemetry.DeviceCollector do
  use GenServer

  @moduledoc """
  Collects, buffers, and periodically flushes telemetry readings from
  a single IoT device. Applies configurable aggregation and threshold
  alerting before forwarding to the time-series backend.
  """

  @flush_interval_ms 5_000
  @max_buffer_size 1_000
  @alert_cooldown_ms 300_000

  defstruct [
    :device_id,
    :device_type,
    :thresholds,
    :buffer,
    :last_flush_at,
    :last_reading,
    :flush_count,
    :alert_cooldowns
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a telemetry
  # collector process per IoT device outside any supervision tree. In an industrial
  # deployment this can mean thousands of simultaneous unsupervised processes. If a
  # device collector crashes (e.g., due to a malformed sensor reading value), all
  # buffered telemetry for that device is lost and data collection stops permanently
  # for that device. No supervisor is available to restart the collector.
  def connect(device_id, config) do
    state = %__MODULE__{
      device_id: device_id,
      device_type: config.device_type,
      thresholds: Map.get(config, :thresholds, %{}),
      buffer: [],
      last_flush_at: nil,
      last_reading: nil,
      flush_count: 0,
      alert_cooldowns: %{}
    }

    GenServer.start(__MODULE__, state, name: via_name(device_id))
  end
  # VALIDATION: SMELL END

  @doc "Ingests a new sensor reading from the device."
  def ingest(device_id, reading) do
    GenServer.cast(via_name(device_id), {:reading, reading})
  end

  @doc "Forces a buffer flush to the time-series backend."
  def flush(device_id) do
    GenServer.call(via_name(device_id), :flush)
  end

  @doc "Returns current buffer stats and last reading."
  def stats(device_id) do
    GenServer.call(via_name(device_id), :stats)
  end

  @doc "Updates alert thresholds for the device."
  def update_thresholds(device_id, thresholds) do
    GenServer.cast(via_name(device_id), {:update_thresholds, thresholds})
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_flush()
    {:ok, state}
  end

  @impl true
  def handle_cast({:reading, reading}, state) do
    enriched = Map.merge(reading, %{received_at: DateTime.utc_now(), device_id: state.device_id})
    new_state = check_thresholds(%{state | last_reading: enriched}, enriched)

    if length(new_state.buffer) >= @max_buffer_size do
      flushed_state = do_flush(new_state)
      {:noreply, %{flushed_state | buffer: [enriched | flushed_state.buffer]}}
    else
      {:noreply, %{new_state | buffer: [enriched | new_state.buffer]}}
    end
  end

  def handle_cast({:update_thresholds, thresholds}, state) do
    {:noreply, %{state | thresholds: thresholds}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = do_flush(state)
    {:reply, {:ok, length(state.buffer)}, new_state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      device_id: state.device_id,
      device_type: state.device_type,
      buffer_size: length(state.buffer),
      last_reading: state.last_reading,
      last_flush_at: state.last_flush_at,
      flush_count: state.flush_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  defp check_thresholds(state, reading) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.thresholds, state, fn {metric, threshold}, acc ->
      value = Map.get(reading, metric)

      if value != nil and threshold_exceeded?(value, threshold) do
        last_alert = Map.get(acc.alert_cooldowns, metric, 0)

        if now - last_alert > @alert_cooldown_ms do
          emit_alert(acc.device_id, metric, value, threshold)
          new_cooldowns = Map.put(acc.alert_cooldowns, metric, now)
          %{acc | alert_cooldowns: new_cooldowns}
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp threshold_exceeded?(value, %{max: max}) when value > max, do: true
  defp threshold_exceeded?(value, %{min: min}) when value < min, do: true
  defp threshold_exceeded?(_value, _threshold), do: false

  defp do_flush(%{buffer: []} = state), do: state

  defp do_flush(state) do
    # Simulated write to time-series backend
    readings = Enum.reverse(state.buffer)
    write_to_backend(state.device_id, readings)

    %{
      state
      | buffer: [],
        last_flush_at: DateTime.utc_now(),
        flush_count: state.flush_count + 1
    }
  end

  defp write_to_backend(_device_id, _readings), do: :ok

  defp emit_alert(_device_id, _metric, _value, _threshold), do: :ok

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp via_name(device_id) do
    {:via, Registry, {Telemetry.DeviceRegistry, device_id}}
  end
end
```
