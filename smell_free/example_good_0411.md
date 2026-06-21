```elixir
defmodule Comms.PresenceDiffHandler do
  @moduledoc """
  Processes Phoenix Presence diff events and maintains a compact view of
  who is currently present in each topic. The handler translates raw
  Phoenix Presence `joins` and `leaves` maps into typed presence records
  and exposes a clean query API. State is held entirely inside the GenServer,
  keeping Phoenix Presence as an implementation detail.
  """

  use GenServer

  @type user_id :: String.t()
  @type topic :: String.t()
  @type presence :: %{user_id: user_id(), meta: map(), joined_at: DateTime.t()}

  @doc "Starts the presence diff handler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all currently present users in `topic`."
  @spec present_in(topic()) :: [presence()]
  def present_in(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:present_in, topic})
  end

  @doc "Returns the total count of unique users across all tracked topics."
  @spec total_unique_users() :: non_neg_integer()
  def total_unique_users do
    GenServer.call(__MODULE__, :total_unique_users)
  end

  @doc "Returns true when `user_id` is present in any tracked topic."
  @spec online?(user_id()) :: boolean()
  def online?(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:online?, user_id})
  end

  @doc "Applies a Phoenix Presence diff event to the current state."
  @spec apply_diff(topic(), map(), map()) :: :ok
  def apply_diff(topic, joins, leaves) do
    GenServer.cast(__MODULE__, {:diff, topic, joins, leaves})
  end

  @impl GenServer
  def init(_opts) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "phoenix:presence")
    {:ok, %{topics: %{}}}
  end

  @impl GenServer
  def handle_call({:present_in, topic}, _from, state) do
    presences = state.topics |> Map.get(topic, %{}) |> Map.values()
    {:reply, presences, state}
  end

  def handle_call(:total_unique_users, _from, state) do
    count =
      state.topics
      |> Enum.flat_map(fn {_topic, users} -> Map.keys(users) end)
      |> Enum.uniq()
      |> length()

    {:reply, count, state}
  end

  def handle_call({:online?, user_id}, _from, state) do
    found = Enum.any?(state.topics, fn {_topic, users} -> Map.has_key?(users, user_id) end)
    {:reply, found, state}
  end

  @impl GenServer
  def handle_cast({:diff, topic, joins, leaves}, state) do
    topic_users = Map.get(state.topics, topic, %{})

    after_leaves =
      Enum.reduce(Map.keys(leaves), topic_users, fn user_id, acc ->
        Map.delete(acc, user_id)
      end)

    after_joins =
      Enum.reduce(joins, after_leaves, fn {user_id, %{metas: [meta | _]}}, acc ->
        presence = %{user_id: user_id, meta: meta, joined_at: DateTime.utc_now()}
        Map.put(acc, user_id, presence)
      end)

    {:noreply, put_in(state, [:topics, topic], after_joins)}
  end

  @impl GenServer
  def handle_info({:presence_diff, %{topic: topic, joins: joins, leaves: leaves}}, state) do
    {:noreply, apply_diff_to_state(state, topic, joins, leaves)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_diff_to_state(state, topic, joins, leaves) do
    topic_users = Map.get(state.topics, topic, %{})
    after_leaves = Enum.reduce(Map.keys(leaves), topic_users, &Map.delete(&2, &1))
    after_joins =
      Enum.reduce(joins, after_leaves, fn {uid, %{metas: [meta | _]}}, acc ->
        Map.put(acc, uid, %{user_id: uid, meta: meta, joined_at: DateTime.utc_now()})
      end)
    put_in(state, [:topics, topic], after_joins)
  end
end
```
