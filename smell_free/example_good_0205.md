# File: `example_good_205.md`

```elixir
defmodule Presence.Tracker do
  @moduledoc """
  GenServer that tracks online presence for user sessions, broadcasting
  join and leave events via Phoenix.PubSub.

  Sessions are identified by a `{user_id, session_id}` pair. A user is
  considered online as long as at least one of their sessions is active.
  Stale sessions are expired automatically using process monitoring:
  when the registering process exits, its session is removed.
  """

  use GenServer

  alias Phoenix.PubSub

  @pubsub MyApp.PubSub
  @presence_topic "presence:users"

  @type user_id :: String.t()
  @type session_id :: String.t()
  @type session_meta :: map()

  @type session_entry :: %{
          user_id: user_id(),
          session_id: session_id(),
          meta: session_meta(),
          pid: pid()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers the calling process as an active session for `user_id`.

  When the calling process exits, the session is automatically removed
  and a leave event is broadcast if this was the user's last session.
  """
  @spec track(user_id(), session_id(), session_meta()) :: :ok
  def track(user_id, session_id, meta \\ %{})
      when is_binary(user_id) and is_binary(session_id) and is_map(meta) do
    GenServer.call(__MODULE__, {:track, user_id, session_id, meta, self()})
  end

  @doc """
  Explicitly removes a session without waiting for the owning process to exit.
  """
  @spec untrack(user_id(), session_id()) :: :ok
  def untrack(user_id, session_id) when is_binary(user_id) and is_binary(session_id) do
    GenServer.cast(__MODULE__, {:untrack, user_id, session_id})
  end

  @doc """
  Returns `true` when the user has at least one active session.
  """
  @spec online?(user_id()) :: boolean()
  def online?(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:online?, user_id})
  end

  @doc """
  Returns all active sessions for a given user.
  """
  @spec sessions(user_id()) :: [session_entry()]
  def sessions(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:sessions, user_id})
  end

  @doc """
  Returns the count of distinct users currently online.
  """
  @spec online_count() :: non_neg_integer()
  def online_count do
    GenServer.call(__MODULE__, :online_count)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{sessions: %{}, monitors: %{}}}

  @impl GenServer
  def handle_call({:track, user_id, session_id, meta, pid}, _from, state) do
    ref = Process.monitor(pid)
    key = {user_id, session_id}
    entry = %{user_id: user_id, session_id: session_id, meta: meta, pid: pid}
    was_online = user_online?(state, user_id)

    new_state = %{state |
      sessions: Map.put(state.sessions, key, entry),
      monitors: Map.put(state.monitors, ref, key)
    }

    unless was_online, do: broadcast_join(user_id, meta)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:online?, user_id}, _from, state) do
    {:reply, user_online?(state, user_id), state}
  end

  @impl GenServer
  def handle_call({:sessions, user_id}, _from, state) do
    entries = state.sessions |> Map.values() |> Enum.filter(&(&1.user_id == user_id))
    {:reply, entries, state}
  end

  @impl GenServer
  def handle_call(:online_count, _from, state) do
    count = state.sessions |> Map.values() |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:untrack, user_id, session_id}, state) do
    {:noreply, remove_session(state, {user_id, session_id})}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, key} ->
        new_monitors = Map.delete(state.monitors, ref)
        new_state = remove_session(%{state | monitors: new_monitors}, key)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  defp remove_session(state, {user_id, _session_id} = key) do
    was_online = user_online?(state, user_id)
    new_sessions = Map.delete(state.sessions, key)
    new_state = %{state | sessions: new_sessions}

    if was_online and not user_online?(new_state, user_id) do
      broadcast_leave(user_id)
    end

    new_state
  end

  defp user_online?(state, user_id) do
    Enum.any?(state.sessions, fn {_key, entry} -> entry.user_id == user_id end)
  end

  defp broadcast_join(user_id, meta) do
    PubSub.broadcast(@pubsub, @presence_topic, {:user_joined, user_id, meta})
  end

  defp broadcast_leave(user_id) do
    PubSub.broadcast(@pubsub, @presence_topic, {:user_left, user_id})
  end
end
```
