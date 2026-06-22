```elixir
defmodule Devices.Telemetry.HeartbeatMonitor do
  @moduledoc """
  Monitors device heartbeat signals. Devices register themselves;
  the monitor raises `:device_silent` events when heartbeats are overdue.
  """

  use GenServer

  @check_interval_ms 10_000

  @type device_state :: %{
          device_id: String.t(),
          last_seen: integer(),
          timeout_ms: pos_integer()
        }
  @type state :: %{devices: %{String.t() => device_state()}, event_handler: function()}

  @doc """
  Starts the HeartbeatMonitor linked to the calling process.

  ## Options
    - `:event_handler` - 1-arity function called with `{:device_silent, device_id}` events.
    - `:check_interval_ms` - how often to poll for silent devices (default: 10_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a device with a heartbeat timeout. Replaces any existing registration.
  """
  @spec register(String.t(), pos_integer()) :: :ok
  def register(device_id, timeout_ms)
      when is_binary(device_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.cast(__MODULE__, {:register, device_id, timeout_ms})
  end

  @doc """
  Records a heartbeat signal from the given device.
  """
  @spec heartbeat(String.t()) :: :ok | {:error, :unregistered}
  def heartbeat(device_id) when is_binary(device_id) do
    GenServer.call(__MODULE__, {:heartbeat, device_id})
  end

  @doc """
  Removes a device from monitoring.
  """
  @spec deregister(String.t()) :: :ok
  def deregister(device_id) when is_binary(device_id) do
    GenServer.cast(__MODULE__, {:deregister, device_id})
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :event_handler)
    interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)
    schedule_check(interval)
    {:ok, %{devices: %{}, event_handler: handler, check_interval_ms: interval}}
  end

  @impl GenServer
  def handle_cast({:register, device_id, timeout_ms}, state) do
    device = %{device_id: device_id, last_seen: now(), timeout_ms: timeout_ms}
    {:noreply, %{state | devices: Map.put(state.devices, device_id, device)}}
  end

  @impl GenServer
  def handle_cast({:deregister, device_id}, state) do
    {:noreply, %{state | devices: Map.delete(state.devices, device_id)}}
  end

  @impl GenServer
  def handle_call({:heartbeat, device_id}, _from, state) do
    case Map.fetch(state.devices, device_id) do
      {:ok, device} ->
        updated = %{device | last_seen: now()}
        {:reply, :ok, %{state | devices: Map.put(state.devices, device_id, updated)}}

      :error ->
        {:reply, {:error, :unregistered}, state}
    end
  end

  @impl GenServer
  def handle_info(:check_heartbeats, state) do
    current = now()

    Enum.each(state.devices, fn {device_id, device} ->
      if current - device.last_seen > device.timeout_ms do
        state.event_handler.({:device_silent, device_id})
      end
    end)

    schedule_check(state.check_interval_ms)
    {:noreply, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_check(interval), do: Process.send_after(self(), :check_heartbeats, interval)
end
```
