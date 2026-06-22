```elixir
defmodule MyApp.Comms.TypingIndicator do
  @moduledoc """
  Tracks real-time typing indicators for collaborative chat channels.
  When a user starts typing, their presence is recorded with a short
  TTL. A periodic sweep removes stale entries so that indicators
  disappear automatically when a user stops typing without explicitly
  sending a stop event.

  Messages are broadcast over PubSub so that any subscriber — LiveView,
  Channel, or mobile push bridge — receives updates instantly.
  """

  use GenServer

  @pubsub MyApp.PubSub
  @typing_ttl_ms 5_000
  @sweep_interval_ms 2_000

  @type channel_id :: String.t()
  @type user_id :: String.t()
  @type entry :: %{user_id: user_id(), expires_at: integer()}

  @doc "Starts the typing indicator server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records that `user_id` is currently typing in `channel_id`.
  Broadcasts `:typing_started` when the user was not previously typing.
  """
  @spec start_typing(channel_id(), user_id()) :: :ok
  def start_typing(channel_id, user_id)
      when is_binary(channel_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:start, channel_id, user_id})
  end

  @doc """
  Removes the typing indicator for `user_id` in `channel_id`.
  Broadcasts `:typing_stopped` when the user was previously typing.
  """
  @spec stop_typing(channel_id(), user_id()) :: :ok
  def stop_typing(channel_id, user_id)
      when is_binary(channel_id) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:stop, channel_id, user_id})
  end

  @doc "Returns the list of users currently typing in `channel_id`."
  @spec typing_users(channel_id()) :: [user_id()]
  def typing_users(channel_id) when is_binary(channel_id) do
    GenServer.call(__MODULE__, {:list, channel_id})
  end

  @doc "Subscribes the calling process to typing events for `channel_id`."
  @spec subscribe(channel_id()) :: :ok | {:error, term()}
  def subscribe(channel_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel_id))

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{channels: %{}}}
  end

  @impl GenServer
  def handle_cast({:start, channel_id, user_id}, state) do
    now = mono_ms()
    channel = Map.get(state.channels, channel_id, %{})
    was_typing = Map.has_key?(channel, user_id)
    entry = %{user_id: user_id, expires_at: now + @typing_ttl_ms}
    updated = %{state | channels: Map.put(state.channels, channel_id, Map.put(channel, user_id, entry))}

    unless was_typing do
      broadcast(channel_id, {:typing_started, user_id})
    end

    {:noreply, updated}
  end

  @impl GenServer
  def handle_cast({:stop, channel_id, user_id}, state) do
    channel = Map.get(state.channels, channel_id, %{})

    if Map.has_key?(channel, user_id) do
      updated_channel = Map.delete(channel, user_id)
      broadcast(channel_id, {:typing_stopped, user_id})
      {:noreply, %{state | channels: Map.put(state.channels, channel_id, updated_channel)}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:list, channel_id}, _from, state) do
    users =
      state.channels
      |> Map.get(channel_id, %{})
      |> Map.keys()

    {:reply, users, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = mono_ms()

    updated_channels =
      Map.new(state.channels, fn {channel_id, entries} ->
        {expired, active} = Enum.split_with(entries, fn {_, e} -> e.expires_at <= now end)

        Enum.each(expired, fn {user_id, _} ->
          broadcast(channel_id, {:typing_stopped, user_id})
        end)

        {channel_id, Map.new(active)}
      end)

    schedule_sweep()
    {:noreply, %{state | channels: updated_channels}}
  end

  @spec broadcast(channel_id(), term()) :: :ok | {:error, term()}
  defp broadcast(channel_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(channel_id), message)
  end

  @spec topic(channel_id()) :: String.t()
  defp topic(channel_id), do: "typing:#{channel_id}"

  @spec mono_ms() :: integer()
  defp mono_ms, do: System.monotonic_time(:millisecond)

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
