```elixir
defmodule Realtime.ConnectionRegistry do
  @moduledoc """
  Tracks active WebSocket connections and their subscribed topics using
  a Registry in duplicate mode. Provides fanout broadcasting, per-user
  connection counts, and a graceful disconnect helper that unregisters
  the calling process from all topics at once. Reads go directly to
  the Registry for O(1) lookup; writes are handled by Registry primitives.
  """

  @registry __MODULE__
  @type conn_id :: String.t()
  @type topic :: String.t()
  @type conn_meta :: %{conn_id: conn_id(), user_id: String.t() | nil, joined_at: DateTime.t()}

  @doc "Returns the child spec for embedding the Registry in a supervision tree."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry, partitions: System.schedulers_online())
  end

  @doc """
  Registers the calling process under `topic` with the given metadata.
  Returns `{:ok, conn_id}` where `conn_id` is a freshly generated identifier.
  """
  @spec join(topic(), String.t() | nil) :: {:ok, conn_id()}
  def join(topic, user_id \\ nil) when is_binary(topic) do
    conn_id = generate_conn_id()
    meta = %{conn_id: conn_id, user_id: user_id, joined_at: DateTime.utc_now()}
    {:ok, _} = Registry.register(@registry, topic, meta)
    {:ok, conn_id}
  end

  @doc "Unregisters the calling process from all topics."
  @spec leave_all() :: :ok
  def leave_all do
    @registry
    |> Registry.keys(self())
    |> Enum.each(fn topic -> Registry.unregister(@registry, topic) end)

    :ok
  end

  @doc "Broadcasts `message` to all processes subscribed to `topic`."
  @spec broadcast(topic(), term()) :: non_neg_integer()
  def broadcast(topic, message) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.reduce(0, fn {pid, _meta}, count ->
      send(pid, message)
      count + 1
    end)
  end

  @doc "Returns all connection metadata records for `topic`."
  @spec connections(topic()) :: [conn_meta()]
  def connections(topic) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.map(fn {_pid, meta} -> meta end)
  end

  @doc "Returns the number of connections subscribed to `topic`."
  @spec connection_count(topic()) :: non_neg_integer()
  def connection_count(topic) when is_binary(topic) do
    Registry.count_match(@registry, topic, :_)
  end

  @doc "Returns the count of unique user IDs subscribed to `topic`."
  @spec unique_user_count(topic()) :: non_neg_integer()
  def unique_user_count(topic) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.map(fn {_pid, %{user_id: uid}} -> uid end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  @doc "Returns all topics the calling process is currently subscribed to."
  @spec my_topics() :: [topic()]
  def my_topics, do: Registry.keys(@registry, self())

  defp generate_conn_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
