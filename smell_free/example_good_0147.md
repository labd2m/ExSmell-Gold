```elixir
defmodule Realtime.ChannelRegistry do
  @moduledoc """
  Tracks active WebSocket channel PIDs keyed by a user-scoped topic. Built
  on top of Elixir's `Registry` module using the `:duplicate` mode so a
  single user may hold multiple connections simultaneously. Down messages
  are handled automatically by the Registry; no manual cleanup is required.
  """

  @registry __MODULE__

  @type topic :: String.t()
  @type user_id :: String.t()
  @type channel_info :: %{pid: pid(), joined_at: DateTime.t(), meta: map()}

  @doc "Returns the child spec for embedding in a supervision tree."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Registers the calling process under `topic`. The registration is
  automatically removed when the process exits.
  """
  @spec register(topic(), map()) :: {:ok, pid()} | {:error, term()}
  def register(topic, meta \\ %{}) when is_binary(topic) and is_map(meta) do
    value = %{pid: self(), joined_at: DateTime.utc_now(), meta: meta}

    case Registry.register(@registry, topic, value) do
      {:ok, _} -> {:ok, self()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns all channel info structs registered under `topic`."
  @spec lookup(topic()) :: [channel_info()]
  def lookup(topic) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.map(fn {_pid, value} -> value end)
  end

  @doc "Returns all topics the given process is currently registered under."
  @spec topics_for_pid(pid()) :: [topic()]
  def topics_for_pid(pid) when is_pid(pid) do
    Registry.keys(@registry, pid)
  end

  @doc "Returns all active PIDs subscribed to the given topic."
  @spec pids_for_topic(topic()) :: [pid()]
  def pids_for_topic(topic) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.map(fn {pid, _value} -> pid end)
  end

  @doc """
  Broadcasts `message` to all processes registered under `topic`.
  Returns the count of recipients reached.
  """
  @spec broadcast(topic(), term()) :: non_neg_integer()
  def broadcast(topic, message) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.reduce(0, fn {pid, _value}, count ->
      send(pid, message)
      count + 1
    end)
  end

  @doc "Returns the total count of active registrations across all topics."
  @spec total_connections() :: non_neg_integer()
  def total_connections do
    Registry.count(@registry)
  end

  @doc "Returns a map of topic to connection count for all active topics."
  @spec connection_counts() :: %{topic() => non_neg_integer()}
  def connection_counts do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
  end
end
```
