# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `PresenceTracker.start/1`
- **Affected function(s):** `PresenceTracker.start/1`, `PresenceManager.track_user/2`
- **Short explanation:** A separate `GenServer` is started for each online user to track their presence state. `GenServer.start/3` is used with no supervisor, so if a tracker process crashes the user appears stuck as "online" and there is no mechanism to clean up or restart the process.

```elixir
defmodule PresenceTracker do
  use GenServer

  @moduledoc """
  Tracks a single user's online presence, device list, and last-seen timestamps.
  Sends heartbeat timeouts and emits presence-changed events.
  """

  @heartbeat_interval_ms 15_000
  @offline_after_ms 45_000

  defstruct [:user_id, :status, :devices, :last_seen, :metadata]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because one process per online user is created
  # using `GenServer.start/3`, keeping all of them outside any supervision tree.
  # In a system with thousands of concurrent users, none of these processes can
  # be monitored collectively, restarted on crash, or enumerated by the
  # application's lifecycle management infrastructure.
  def start(user_id) do
    GenServer.start(__MODULE__, user_id, name: via(user_id))
  end
  # VALIDATION: SMELL END

  def heartbeat(user_id, device_info \\ %{}) do
    GenServer.cast(via(user_id), {:heartbeat, device_info})
  end

  def go_offline(user_id) do
    GenServer.cast(via(user_id), :offline)
  end

  def get_presence(user_id) do
    GenServer.call(via(user_id), :get)
  end

  def update_metadata(user_id, meta) do
    GenServer.cast(via(user_id), {:update_meta, meta})
  end

  defp via(id), do: {:via, Registry, {PresenceRegistry, id}}

  ## Callbacks

  @impl true
  def init(user_id) do
    state = %__MODULE__{
      user_id: user_id,
      status: :online,
      devices: [],
      last_seen: DateTime.utc_now(),
      metadata: %{}
    }

    schedule_heartbeat_check()
    {:ok, state}
  end

  @impl true
  def handle_cast({:heartbeat, device_info}, state) do
    now = DateTime.utc_now()
    devices = update_device_list(state.devices, device_info)
    {:noreply, %{state | last_seen: now, status: :online, devices: devices}}
  end

  def handle_cast(:offline, state) do
    emit_presence_event(state.user_id, :offline)
    {:stop, :normal, %{state | status: :offline}}
  end

  def handle_cast({:update_meta, meta}, state) do
    {:noreply, %{state | metadata: Map.merge(state.metadata, meta)}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    presence = %{
      user_id: state.user_id,
      status: state.status,
      devices: state.devices,
      last_seen: state.last_seen,
      metadata: state.metadata
    }

    {:reply, {:ok, presence}, state}
  end

  @impl true
  def handle_info(:heartbeat_check, state) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), state.last_seen, :millisecond)

    if elapsed_ms > @offline_after_ms do
      emit_presence_event(state.user_id, :timeout_offline)
      {:stop, :normal, %{state | status: :offline}}
    else
      schedule_heartbeat_check()
      {:noreply, state}
    end
  end

  defp update_device_list(devices, %{device_id: id} = info) do
    case Enum.find_index(devices, &(&1.device_id == id)) do
      nil -> [info | devices]
      idx -> List.replace_at(devices, idx, info)
    end
  end

  defp update_device_list(devices, _), do: devices

  defp emit_presence_event(user_id, event) do
    IO.inspect({user_id, event}, label: "[PresenceTracker] event")
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :heartbeat_check, @heartbeat_interval_ms)
  end
end

defmodule PresenceManager do
  @moduledoc "Public API for user presence tracking."

  def track_user(user_id, initial_device \\ %{}) do
    with {:ok, _pid} <- PresenceTracker.start(user_id) do
      PresenceTracker.heartbeat(user_id, initial_device)
      {:ok, user_id}
    end
  end

  def online_users do
    Registry.select(PresenceRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
```
