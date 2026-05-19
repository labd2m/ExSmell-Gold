```elixir
defmodule ChatRoom do
  use GenServer

  @moduledoc """
  Manages a single chat room including participant membership,
  message history, and real-time delivery to connected subscribers.
  """

  @max_history 500

  defstruct [
    :room_id,
    :name,
    :created_by,
    :created_at,
    :type,
    participants: %{},
    messages: [],
    subscribers: []
  ]

  def start(%{room_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def join(room_id, user_id, display_name) do
    GenServer.call(via(room_id), {:join, user_id, display_name})
  end

  def leave(room_id, user_id) do
    GenServer.call(via(room_id), {:leave, user_id})
  end

  def send_message(room_id, user_id, content) do
    GenServer.call(via(room_id), {:message, user_id, content})
  end

  def get_history(room_id, limit \\ 50) do
    GenServer.call(via(room_id), {:history, limit})
  end

  def participants(room_id) do
    GenServer.call(via(room_id), :participants)
  end

  def subscribe(room_id, subscriber_pid) do
    GenServer.cast(via(room_id), {:subscribe, subscriber_pid})
  end

  defp via(id), do: {:via, Registry, {ChatRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{room_id: id, name: name, created_by: user_id, type: type}) do
    state = %__MODULE__{
      room_id: id,
      name: name,
      created_by: user_id,
      created_at: DateTime.utc_now(),
      type: type
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, user_id, display_name}, _from, state) do
    participant = %{user_id: user_id, display_name: display_name, joined_at: DateTime.utc_now()}
    participants = Map.put(state.participants, user_id, participant)

    system_message = build_message(:system, "#{display_name} joined the room")
    messages = prepend_message(system_message, state.messages)

    broadcast(state.subscribers, {:user_joined, participant})
    {:reply, :ok, %{state | participants: participants, messages: messages}}
  end

  def handle_call({:leave, user_id}, _from, state) do
    {participant, participants} = Map.pop(state.participants, user_id)
    display_name = if participant, do: participant.display_name, else: user_id

    system_message = build_message(:system, "#{display_name} left the room")
    messages = prepend_message(system_message, state.messages)

    broadcast(state.subscribers, {:user_left, user_id})
    {:reply, :ok, %{state | participants: participants, messages: messages}}
  end

  def handle_call({:message, user_id, content}, _from, state) do
    msg = build_message(user_id, content)
    messages = prepend_message(msg, state.messages)
    broadcast(state.subscribers, {:new_message, msg})
    {:reply, {:ok, msg}, %{state | messages: messages}}
  end

  def handle_call({:history, limit}, _from, state) do
    history = state.messages |> Enum.reverse() |> Enum.take(limit)
    {:reply, history, state}
  end

  def handle_call(:participants, _from, state) do
    {:reply, Map.values(state.participants), state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  defp build_message(sender, content) do
    %{id: make_ref(), sender: sender, content: content, sent_at: DateTime.utc_now()}
  end

  defp prepend_message(msg, messages) do
    [msg | messages] |> Enum.take(@max_history)
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, &send(&1, event))
  end
end

defmodule ChatServer do
  @moduledoc "API for creating and managing chat rooms."

  def create_room(room_id, attrs) do
    attrs = Map.merge(%{type: :public}, attrs) |> Map.put(:room_id, room_id)

    case ChatRoom.start(attrs) do
      {:ok, _pid} -> {:ok, room_id}
      {:error, {:already_started, _}} -> {:ok, room_id}
      {:error, reason} -> {:error, reason}
    end
  end
end
```
