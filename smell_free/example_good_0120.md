```elixir
defmodule Devices.PresenceTracker do
  @moduledoc """
  Tracks which devices are currently online using a GenServer that maintains
  a heartbeat registry. Devices emit periodic heartbeats; those that miss
  two consecutive intervals are marked offline. The tracker emits telemetry
  events on status transitions so monitoring infrastructure remains decoupled.
  """

  use GenServer

  require Logger

  @type device_id :: String.t()
  @type device_status :: :online | :offline
  @type device_entry :: %{last_seen: integer(), status: device_status()}

  @heartbeat_interval_ms 30_000
  @expiry_ms @heartbeat_interval_ms * 2 + 5_000

  @doc "Starts the presence tracker and registers it by module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records a heartbeat from `device_id`, marking it online."
  @spec heartbeat(device_id()) :: :ok
  def heartbeat(device_id) when is_binary(device_id) do
    GenServer.cast(__MODULE__, {:heartbeat, device_id})
  end

  @doc "Returns the current status of `device_id`."
  @spec status(device_id()) :: {:ok, device_status()} | {:error, :unknown_device}
  def status(device_id) when is_binary(device_id) do
    GenServer.call(__MODULE__, {:status, device_id})
  end

  @doc "Returns all device IDs currently marked as online."
  @spec online_devices() :: [device_id()]
  def online_devices do
    GenServer.call(__MODULE__, :online_devices)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @heartbeat_interval_ms)
    Process.send_after(self(), :sweep, interval)
    {:ok, %{devices: %{}, sweep_interval: interval}}
  end

  @impl GenServer
  def handle_cast({:heartbeat, device_id}, state) do
    existing = Map.get(state.devices, device_id)
    entry = %{last_seen: now(), status: :online}
    new_state = put_in(state, [:devices, device_id], entry)

    if existing && existing.status == :offline do
      emit_transition(device_id, :online)
    end

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:status, device_id}, _from, state) do
    result =
      case Map.get(state.devices, device_id) do
        nil -> {:error, :unknown_device}
        %{status: s} -> {:ok, s}
      end

    {:reply, result, state}
  end

  def handle_call(:online_devices, _from, state) do
    online =
      state.devices
      |> Enum.filter(fn {_id, e} -> e.status == :online end)
      |> Enum.map(fn {id, _e} -> id end)

    {:reply, online, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    cutoff = now() - @expiry_ms

    updated =
      Map.new(state.devices, fn {id, entry} ->
        if entry.status == :online and entry.last_seen < cutoff do
          emit_transition(id, :offline)
          {id, %{entry | status: :offline}}
        else
          {id, entry}
        end
      end)

    Process.send_after(self(), :sweep, interval)
    {:noreply, %{state | devices: updated}}
  end

  defp emit_transition(device_id, new_status) do
    :telemetry.execute(
      [:devices, :presence, :transition],
      %{system_time: System.system_time()},
      %{device_id: device_id, status: new_status}
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```
