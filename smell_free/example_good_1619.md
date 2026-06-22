```elixir
defmodule Collab.PresenceTracker do
  @moduledoc """
  Tracks which users are currently active within named collaboration rooms.

  Each room's presence set is maintained independently. Stale entries are
  evicted automatically after a configurable heartbeat timeout.
  """

  use GenServer

  alias Collab.PresenceTracker.{RoomState, PresenceEntry}

  @heartbeat_timeout_ms 30_000
  @cleanup_interval_ms 15_000

  @type room_id :: String.t()
  @type user_id :: String.t()

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Registers a user as present in a room, refreshing their heartbeat timestamp.
  """
  @spec join(room_id(), user_id(), map()) :: :ok
  def join(room_id, user_id, metadata \\ %{})
      when is_binary(room_id) and is_binary(user_id) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:join, room_id, user_id, metadata})
  end

  @doc """
  Removes a user from a room's presence set.
  """
  @spec leave(room_id(), user_id()) :: :ok
  def leave(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:leave, room_id, user_id})
  end

  @doc """
  Refreshes a user's heartbeat to prevent eviction.
  """
  @spec heartbeat(room_id(), user_id()) :: :ok
  def heartbeat(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:heartbeat, room_id, user_id})
  end

  @doc """
  Returns the list of currently active presence entries for a room.
  """
  @spec list(room_id()) :: [PresenceEntry.t()]
  def list(room_id) when is_binary(room_id) do
    GenServer.call(__MODULE__, {:list, room_id})
  end

  @impl GenServer
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:join, room_id, user_id, metadata}, rooms) do
    entry = PresenceEntry.new(user_id, metadata)
    updated = Map.update(rooms, room_id, RoomState.new(entry), &RoomState.put(&1, entry))
    {:noreply, updated}
  end

  def handle_cast({:leave, room_id, user_id}, rooms) do
    updated = Map.update(rooms, room_id, RoomState.empty(), &RoomState.delete(&1, user_id))
    {:noreply, updated}
  end

  def handle_cast({:heartbeat, room_id, user_id}, rooms) do
    updated = Map.update(rooms, room_id, RoomState.empty(), &RoomState.refresh(&1, user_id))
    {:noreply, updated}
  end

  @impl GenServer
  def handle_call({:list, room_id}, _from, rooms) do
    entries = rooms |> Map.get(room_id, RoomState.empty()) |> RoomState.active_entries()
    {:reply, entries, rooms}
  end

  @impl GenServer
  def handle_info(:cleanup, rooms) do
    cutoff = System.monotonic_time(:millisecond) - @heartbeat_timeout_ms
    pruned = Map.new(rooms, fn {rid, rs} -> {rid, RoomState.evict_stale(rs, cutoff)} end)
    schedule_cleanup()
    {:noreply, pruned}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end

defmodule Collab.PresenceTracker.PresenceEntry do
  @moduledoc false

  @enforce_keys [:user_id, :metadata, :last_seen_at]
  defstruct [:user_id, :metadata, :last_seen_at]

  @type t :: %__MODULE__{
          user_id: String.t(),
          metadata: map(),
          last_seen_at: integer()
        }

  @spec new(String.t(), map()) :: t()
  def new(user_id, metadata) do
    %__MODULE__{user_id: user_id, metadata: metadata, last_seen_at: System.monotonic_time(:millisecond)}
  end

  @spec refresh(t()) :: t()
  def refresh(entry), do: %{entry | last_seen_at: System.monotonic_time(:millisecond)}
end

defmodule Collab.PresenceTracker.RoomState do
  @moduledoc false

  alias Collab.PresenceTracker.PresenceEntry

  @type t :: %{String.t() => PresenceEntry.t()}

  @spec empty() :: t()
  def empty, do: %{}

  @spec new(PresenceEntry.t()) :: t()
  def new(%PresenceEntry{user_id: uid} = entry), do: %{uid => entry}

  @spec put(t(), PresenceEntry.t()) :: t()
  def put(room, %PresenceEntry{user_id: uid} = entry), do: Map.put(room, uid, entry)

  @spec delete(t(), String.t()) :: t()
  def delete(room, user_id), do: Map.delete(room, user_id)

  @spec refresh(t(), String.t()) :: t()
  def refresh(room, user_id) do
    Map.update(room, user_id, nil, &PresenceEntry.refresh/1)
  end

  @spec active_entries(t()) :: [PresenceEntry.t()]
  def active_entries(room), do: Map.values(room)

  @spec evict_stale(t(), integer()) :: t()
  def evict_stale(room, cutoff) do
    Map.filter(room, fn {_uid, entry} -> entry.last_seen_at >= cutoff end)
  end
end
```
