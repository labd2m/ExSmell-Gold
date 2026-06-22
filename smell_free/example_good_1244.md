```elixir
defmodule Realtime.Presence.Tracker do
  @moduledoc """
  Tracks online presence of users within named rooms.
  Presence records include join timestamp and optional metadata.
  All state is maintained within a supervised GenServer.
  """

  use GenServer

  @type user_id :: String.t()
  @type room_id :: String.t()
  @type presence :: %{user_id: user_id(), joined_at: DateTime.t(), metadata: map()}
  @type state :: %{rooms: %{room_id() => [presence()]}}

  @doc """
  Starts the Tracker linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a user joining a room. Replaces any existing presence for the same user.
  """
  @spec join(room_id(), user_id(), map()) :: :ok
  def join(room_id, user_id, metadata \\ %{})
      when is_binary(room_id) and is_binary(user_id) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:join, room_id, user_id, metadata})
  end

  @doc """
  Removes a user from a room.
  """
  @spec leave(room_id(), user_id()) :: :ok
  def leave(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:leave, room_id, user_id})
  end

  @doc """
  Returns the list of present users in `room_id`.
  """
  @spec list_room(room_id()) :: [presence()]
  def list_room(room_id) when is_binary(room_id) do
    GenServer.call(__MODULE__, {:list_room, room_id})
  end

  @doc """
  Returns the count of users currently in `room_id`.
  """
  @spec count(room_id()) :: non_neg_integer()
  def count(room_id) when is_binary(room_id) do
    GenServer.call(__MODULE__, {:count, room_id})
  end

  @doc """
  Returns all rooms in which `user_id` is currently present.
  """
  @spec rooms_for_user(user_id()) :: [room_id()]
  def rooms_for_user(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:rooms_for_user, user_id})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{rooms: %{}}}

  @impl GenServer
  def handle_cast({:join, room_id, user_id, metadata}, state) do
    presence = %{user_id: user_id, joined_at: DateTime.utc_now(), metadata: metadata}
    room_presences = Map.get(state.rooms, room_id, [])
    updated = [presence | Enum.reject(room_presences, fn p -> p.user_id == user_id end)]
    {:noreply, %{state | rooms: Map.put(state.rooms, room_id, updated)}}
  end

  @impl GenServer
  def handle_cast({:leave, room_id, user_id}, state) do
    updated_rooms =
      Map.update(state.rooms, room_id, [], fn presences ->
        Enum.reject(presences, fn p -> p.user_id == user_id end)
      end)

    {:noreply, %{state | rooms: updated_rooms}}
  end

  @impl GenServer
  def handle_call({:list_room, room_id}, _from, state) do
    {:reply, Map.get(state.rooms, room_id, []), state}
  end

  @impl GenServer
  def handle_call({:count, room_id}, _from, state) do
    {:reply, length(Map.get(state.rooms, room_id, [])), state}
  end

  @impl GenServer
  def handle_call({:rooms_for_user, user_id}, _from, state) do
    rooms =
      state.rooms
      |> Enum.filter(fn {_room, presences} ->
        Enum.any?(presences, fn p -> p.user_id == user_id end)
      end)
      |> Enum.map(fn {room_id, _} -> room_id end)

    {:reply, rooms, state}
  end
end
```
