```elixir
defmodule Presence.Tracker do
  @moduledoc """
  Tracks which users are currently active in named channels using
  Phoenix.Presence, and maintains an aggregated summary GenServer that
  other processes can query without subscribing to individual presence diffs.
  """

  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end

defmodule Presence.ChannelSummary do
  @moduledoc """
  Maintains a real-time summary of per-channel presence counts.

  The process subscribes to the presence system's internal topic and
  rebuilds channel summaries on each diff. External callers query counts
  and membership lists without coupling to Phoenix.Presence internals.
  """

  use GenServer

  alias Presence.Tracker

  @type channel :: String.t()
  @type user_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec count(channel()) :: non_neg_integer()
  def count(channel) when is_binary(channel) do
    GenServer.call(__MODULE__, {:count, channel})
  end

  @spec members(channel()) :: [user_id()]
  def members(channel) when is_binary(channel) do
    GenServer.call(__MODULE__, {:members, channel})
  end

  @spec active_channels() :: [channel()]
  def active_channels do
    GenServer.call(__MODULE__, :active_channels)
  end

  @impl GenServer
  def init(_opts) do
    MyApp.PubSub |> Phoenix.PubSub.subscribe("presence:diff")
    {:ok, %{channels: %{}}}
  end

  @impl GenServer
  def handle_call({:count, channel}, _from, state) do
    count = state.channels |> Map.get(channel, MapSet.new()) |> MapSet.size()
    {:reply, count, state}
  end

  def handle_call({:members, channel}, _from, state) do
    members = state.channels |> Map.get(channel, MapSet.new()) |> MapSet.to_list()
    {:reply, members, state}
  end

  def handle_call(:active_channels, _from, state) do
    channels =
      state.channels
      |> Enum.reject(fn {_ch, members} -> MapSet.size(members) == 0 end)
      |> Enum.map(fn {ch, _} -> ch end)

    {:reply, channels, state}
  end

  @impl GenServer
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff, topic: topic}, state) do
    channel = String.replace_prefix(topic, "channel:", "")
    updated = apply_diff(state.channels, channel, diff)
    {:noreply, %{state | channels: updated}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_diff(channels, channel, %{joins: joins, leaves: leaves}) do
    current = Map.get(channels, channel, MapSet.new())

    after_joins =
      joins
      |> Map.keys()
      |> Enum.reduce(current, &MapSet.put(&2, &1))

    after_leaves =
      leaves
      |> Map.keys()
      |> Enum.reduce(after_joins, &MapSet.delete(&2, &1))

    Map.put(channels, channel, after_leaves)
  end
end

defmodule Presence.ChannelJoiner do
  @moduledoc """
  Helper for tracking a user's presence when they join a Phoenix Channel.
  """

  alias Presence.Tracker

  @spec track(Phoenix.Socket.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def track(%Phoenix.Socket{} = socket, user_id, metadata \\ %{})
      when is_binary(user_id) and is_map(metadata) do
    Tracker.track(socket, user_id, Map.merge(%{joined_at: System.system_time(:second)}, metadata))
  end
end
```
