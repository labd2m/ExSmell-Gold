```elixir
defmodule IoT.DeviceRegistry do
  @moduledoc """
  Manages connected IoT device registrations, heartbeats, and capability declarations.
  Automatically marks devices as offline after a configurable inactivity timeout.
  """

  use GenServer

  @type device_id :: String.t()
  @type capability :: :temperature | :humidity | :motion | :door | :light
  @type device :: %{
    id: device_id(),
    name: String.t(),
    capabilities: [capability()],
    status: :online | :offline,
    last_seen: integer(),
    metadata: map()
  }
  @type state :: %{devices: %{device_id() => device()}, timeout_ms: pos_integer()}

  @default_timeout_ms 60_000
  @sweep_interval_ms 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    GenServer.start_link(__MODULE__, %{devices: %{}, timeout_ms: timeout_ms}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(device_id(), String.t(), [capability()], map()) ::
          {:ok, device()} | {:error, String.t()}
  def register(id, name, capabilities, metadata \\ %{})
      when is_binary(id) and is_binary(name) and is_list(capabilities) do
    GenServer.call(__MODULE__, {:register, id, name, capabilities, metadata})
  end

  @spec heartbeat(device_id()) :: :ok | {:error, :not_registered}
  def heartbeat(device_id) when is_binary(device_id) do
    GenServer.call(__MODULE__, {:heartbeat, device_id})
  end

  @spec get_device(device_id()) :: {:ok, device()} | {:error, :not_found}
  def get_device(device_id) when is_binary(device_id) do
    GenServer.call(__MODULE__, {:get, device_id})
  end

  @spec online_devices() :: [device()]
  def online_devices, do: GenServer.call(__MODULE__, :online)

  @spec devices_with_capability(capability()) :: [device()]
  def devices_with_capability(capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:by_capability, capability})
  end

  @impl GenServer
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register, id, name, capabilities, metadata}, _from, state) do
    device = %{id: id, name: name, capabilities: capabilities, status: :online,
               last_seen: now(), metadata: metadata}
    {:reply, {:ok, device}, %{state | devices: Map.put(state.devices, id, device)}}
  end

  def handle_call({:heartbeat, device_id}, _from, state) do
    case Map.get(state.devices, device_id) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      device ->
        updated = %{device | status: :online, last_seen: now()}
        {:reply, :ok, %{state | devices: Map.put(state.devices, device_id, updated)}}
    end
  end

  def handle_call({:get, device_id}, _from, state) do
    case Map.get(state.devices, device_id) do
      nil -> {:reply, {:error, :not_found}, state}
      device -> {:reply, {:ok, device}, state}
    end
  end

  def handle_call(:online, _from, state) do
    online = state.devices |> Map.values() |> Enum.filter(&(&1.status == :online))
    {:reply, online, state}
  end

  def handle_call({:by_capability, cap}, _from, state) do
    matched = state.devices |> Map.values() |> Enum.filter(&(cap in &1.capabilities))
    {:reply, matched, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now() - state.timeout_ms
    updated_devices =
      Map.new(state.devices, fn {id, device} ->
        if device.last_seen < cutoff do
          {id, %{device | status: :offline}}
        else
          {id, device}
        end
      end)

    schedule_sweep()
    {:noreply, %{state | devices: updated_devices}}
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
```
