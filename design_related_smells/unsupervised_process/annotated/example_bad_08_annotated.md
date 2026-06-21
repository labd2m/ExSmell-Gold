# Annotated Example 08 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Presence.UserTracker.track/2`
- **Affected function(s):** `track/2`
- **Short explanation:** A new GenServer process is spawned per connected user via `GenServer.start/3` each time `track/2` is called. With many concurrent users, these unsupervised processes are impossible to audit or manage, and any crash quietly removes a user from presence tracking with no recovery path.

```elixir
defmodule Presence.UserTracker do
  use GenServer

  @moduledoc """
  Tracks real-time presence state for a single connected user.
  Maintains heartbeat liveness, current channel membership, and
  idle/active status for display in collaborative features.
  """

  @heartbeat_timeout_ms 30_000
  @idle_after_ms 120_000

  defstruct [
    :user_id,
    :socket_id,
    :status,
    :channels,
    :last_heartbeat,
    :last_activity,
    :metadata
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a separate
  # long-running presence-tracking process for every connected user, entirely
  # outside a supervision tree. In a collaborative application with thousands of
  # concurrent users, this results in thousands of unsupervised processes that
  # cannot be monitored, restarted, or cleanly shut down. A crash in any one of
  # them silently removes that user from presence data with no observable fault.
  def track(user_id, socket_id, metadata \\ %{}) do
    state = %__MODULE__{
      user_id: user_id,
      socket_id: socket_id,
      status: :online,
      channels: MapSet.new(),
      last_heartbeat: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      metadata: metadata
    }

    case GenServer.start(__MODULE__, state, name: via_name(user_id)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> update_socket(user_id, socket_id)
    end
  end
  # VALIDATION: SMELL END

  @doc "Records a heartbeat, resetting the timeout timer."
  def heartbeat(user_id) do
    GenServer.cast(via_name(user_id), :heartbeat)
  end

  @doc "Records user activity, updating idle/active status."
  def record_activity(user_id) do
    GenServer.cast(via_name(user_id), :activity)
  end

  @doc "Joins a user to a named channel for presence purposes."
  def join_channel(user_id, channel) do
    GenServer.cast(via_name(user_id), {:join_channel, channel})
  end

  @doc "Removes a user from a channel."
  def leave_channel(user_id, channel) do
    GenServer.cast(via_name(user_id), {:leave_channel, channel})
  end

  @doc "Returns the current presence state for a user."
  def get_presence(user_id) do
    case GenServer.whereis(via_name(user_id)) do
      nil -> {:error, :offline}
      _pid -> {:ok, GenServer.call(via_name(user_id), :get_presence)}
    end
  end

  @doc "Disconnects the tracker for a user."
  def untrack(user_id) do
    GenServer.stop(via_name(user_id), :normal)
  end

  defp update_socket(user_id, socket_id) do
    GenServer.cast(via_name(user_id), {:update_socket, socket_id})
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_heartbeat_check()
    {:ok, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply, %{state | last_heartbeat: DateTime.utc_now()}}
  end

  def handle_cast(:activity, state) do
    new_state = %{
      state
      | last_activity: DateTime.utc_now(),
        status: :online
    }

    {:noreply, new_state}
  end

  def handle_cast({:join_channel, channel}, state) do
    {:noreply, %{state | channels: MapSet.put(state.channels, channel)}}
  end

  def handle_cast({:leave_channel, channel}, state) do
    {:noreply, %{state | channels: MapSet.delete(state.channels, channel)}}
  end

  def handle_cast({:update_socket, socket_id}, state) do
    {:noreply, %{state | socket_id: socket_id, last_heartbeat: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:get_presence, _from, state) do
    presence = %{
      user_id: state.user_id,
      status: state.status,
      channels: MapSet.to_list(state.channels),
      last_heartbeat: state.last_heartbeat,
      last_activity: state.last_activity,
      metadata: state.metadata
    }

    {:reply, presence, state}
  end

  @impl true
  def handle_info(:check_heartbeat, state) do
    now = DateTime.utc_now()
    ms_since_heartbeat = DateTime.diff(now, state.last_heartbeat, :millisecond)
    ms_since_activity = DateTime.diff(now, state.last_activity, :millisecond)

    cond do
      ms_since_heartbeat > @heartbeat_timeout_ms ->
        {:stop, :normal, state}

      ms_since_activity > @idle_after_ms ->
        schedule_heartbeat_check()
        {:noreply, %{state | status: :idle}}

      true ->
        schedule_heartbeat_check()
        {:noreply, state}
    end
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :check_heartbeat, @heartbeat_timeout_ms)
  end

  defp via_name(user_id) do
    {:via, Registry, {Presence.Registry, user_id}}
  end
end
```
