```elixir
defmodule Realtime.TypingIndicator do
  @moduledoc """
  Tracks per-conversation typing state for real-time chat UI indicators.
  Users signal that they are typing; the state expires automatically after
  a debounce interval so stale indicators clear without requiring an
  explicit stop event. Concurrent connections from the same user are
  handled by treating any active connection as typing.
  """

  use GenServer

  @type user_id :: String.t()
  @type conversation_id :: String.t()
  @type typing_entry :: %{user_id: user_id(), expires_at: integer()}

  @debounce_ms 4_000
  @sweep_interval_ms 2_000

  @doc "Starts the typing indicator tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records that `user_id` is currently typing in `conversation_id`."
  @spec typing(conversation_id(), user_id()) :: :ok
  def typing(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:typing, conversation_id, user_id})
  end

  @doc "Explicitly clears the typing indicator for `user_id` in `conversation_id`."
  @spec stopped(conversation_id(), user_id()) :: :ok
  def stopped(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:stopped, conversation_id, user_id})
  end

  @doc "Returns the IDs of users currently typing in `conversation_id`."
  @spec who_is_typing(conversation_id()) :: [user_id()]
  def who_is_typing(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:who_is_typing, conversation_id})
  end

  @doc "Returns true when `user_id` is currently typing in `conversation_id`."
  @spec typing?(conversation_id(), user_id()) :: boolean()
  def typing?(conversation_id, user_id) do
    user_id in who_is_typing(conversation_id)
  end

  @impl GenServer
  def init(opts) do
    debounce = Keyword.get(opts, :debounce_ms, @debounce_ms)
    sweep = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, sweep)
    {:ok, %{conversations: %{}, debounce_ms: debounce, sweep_interval: sweep}}
  end

  @impl GenServer
  def handle_cast({:typing, conv_id, user_id}, state) do
    expires_at = now_ms() + state.debounce_ms
    entry = %{user_id: user_id, expires_at: expires_at}

    new_conv =
      state.conversations
      |> Map.get(conv_id, [])
      |> Enum.reject(fn e -> e.user_id == user_id end)
      |> then(&[entry | &1])

    broadcast_if_changed(state.conversations, conv_id, new_conv)
    {:noreply, put_in(state, [:conversations, conv_id], new_conv)}
  end

  def handle_cast({:stopped, conv_id, user_id}, state) do
    new_conv =
      state.conversations
      |> Map.get(conv_id, [])
      |> Enum.reject(fn e -> e.user_id == user_id end)

    broadcast_if_changed(state.conversations, conv_id, new_conv)
    {:noreply, put_in(state, [:conversations, conv_id], new_conv)}
  end

  @impl GenServer
  def handle_call({:who_is_typing, conv_id}, _from, state) do
    now = now_ms()
    active =
      state.conversations
      |> Map.get(conv_id, [])
      |> Enum.filter(fn e -> e.expires_at > now end)
      |> Enum.map(& &1.user_id)

    {:reply, active, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: sweep} = state) do
    now = now_ms()

    new_conversations =
      Map.new(state.conversations, fn {conv_id, entries} ->
        {conv_id, Enum.filter(entries, fn e -> e.expires_at > now end)}
      end)
      |> Map.reject(fn {_id, entries} -> Enum.empty?(entries) end)

    Process.send_after(self(), :sweep, sweep)
    {:noreply, %{state | conversations: new_conversations}}
  end

  defp broadcast_if_changed(conversations, conv_id, new_entries) do
    old_users = conversations |> Map.get(conv_id, []) |> Enum.map(& &1.user_id) |> MapSet.new()
    new_users = new_entries |> Enum.map(& &1.user_id) |> MapSet.new()

    unless MapSet.equal?(old_users, new_users) do
      Phoenix.PubSub.broadcast(
        MyApp.PubSub,
        "typing:#{conv_id}",
        {:typing_update, %{conversation_id: conv_id, typing_user_ids: MapSet.to_list(new_users)}}
      )
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
```
