```elixir
defmodule DeviceShadow do
  use GenServer

  @moduledoc """
  Implements an IoT device shadow: maintains desired state (what the cloud wants)
  and reported state (what the device last sent), computing the delta to sync.
  """

  @heartbeat_timeout_ms 60_000

  defstruct [
    :device_id,
    :device_type,
    :firmware_version,
    :connected_at,
    :last_seen,
    :connection_status,
    desired: %{},
    reported: %{},
    delta: %{}
  ]

  def start(%{device_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def update_desired(device_id, properties) do
    GenServer.call(via(device_id), {:update_desired, properties})
  end

  def update_reported(device_id, properties) do
    GenServer.call(via(device_id), {:update_reported, properties})
  end

  def get_delta(device_id) do
    GenServer.call(via(device_id), :delta)
  end

  def get_shadow(device_id) do
    GenServer.call(via(device_id), :shadow)
  end

  def heartbeat(device_id) do
    GenServer.cast(via(device_id), :heartbeat)
  end

  def disconnect(device_id) do
    GenServer.cast(via(device_id), :disconnect)
  end

  defp via(id), do: {:via, Registry, {DeviceShadowRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{device_id: id, device_type: type, firmware_version: fw}) do
    now = DateTime.utc_now()

    state = %__MODULE__{
      device_id: id,
      device_type: type,
      firmware_version: fw,
      connected_at: now,
      last_seen: now,
      connection_status: :connected
    }

    schedule_heartbeat_check()
    {:ok, state}
  end

  @impl true
  def handle_call({:update_desired, props}, _from, state) do
    desired = Map.merge(state.desired, props)
    delta = compute_delta(desired, state.reported)
    {:reply, {:ok, delta}, %{state | desired: desired, delta: delta}}
  end

  def handle_call({:update_reported, props}, _from, state) do
    reported = Map.merge(state.reported, props)
    delta = compute_delta(state.desired, reported)
    {:reply, {:ok, delta}, %{state | reported: reported, delta: delta}}
  end

  def handle_call(:delta, _from, state) do
    {:reply, state.delta, state}
  end

  def handle_call(:shadow, _from, state) do
    shadow = %{
      device_id: state.device_id,
      desired: state.desired,
      reported: state.reported,
      delta: state.delta,
      metadata: %{
        last_seen: state.last_seen,
        connected_at: state.connected_at,
        status: state.connection_status
      }
    }

    {:reply, {:ok, shadow}, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply, %{state | last_seen: DateTime.utc_now(), connection_status: :connected}}
  end

  def handle_cast(:disconnect, state) do
    {:noreply, %{state | connection_status: :disconnected}}
  end

  @impl true
  def handle_info(:heartbeat_check, state) do
    elapsed = DateTime.diff(DateTime.utc_now(), state.last_seen, :millisecond)

    if elapsed > @heartbeat_timeout_ms do
      {:noreply, %{state | connection_status: :disconnected}}
    else
      schedule_heartbeat_check()
      {:noreply, state}
    end
  end

  defp compute_delta(desired, reported) do
    Enum.reduce(desired, %{}, fn {key, val}, acc ->
      if Map.get(reported, key) != val do
        Map.put(acc, key, %{desired: val, reported: Map.get(reported, key)})
      else
        acc
      end
    end)
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :heartbeat_check, @heartbeat_timeout_ms)
  end
end

defmodule DeviceRegistry do
  @moduledoc "Manages device shadow creation and lookup."

  def register(device_id, attrs) do
    case DeviceShadow.start(Map.put(attrs, :device_id, device_id)) do
      {:ok, _pid} -> {:ok, device_id}
      {:error, {:already_started, _}} -> {:ok, device_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_state(device_id, reported_state) do
    DeviceShadow.update_reported(device_id, reported_state)
    DeviceShadow.get_delta(device_id)
  end
end
```
