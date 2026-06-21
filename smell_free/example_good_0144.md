```elixir
defmodule DataSync.ChangesetBroadcaster do
  @moduledoc """
  Listens to Postgres logical replication changes via Postgrex notifications
  and broadcasts structured change events onto Phoenix PubSub. Each table
  maps to a named PubSub topic, enabling downstream modules to subscribe
  without coupling to the replication transport layer.
  """

  use GenServer

  require Logger

  @pubsub MyApp.PubSub
  @channel "data_changes"

  @type table :: String.t()
  @type operation :: :insert | :update | :delete
  @type change_event :: %{table: table(), operation: operation(), payload: map()}

  @doc "Starts the broadcaster and subscribes to the Postgres notification channel."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the PubSub topic name for a given table."
  @spec topic_for_table(table()) :: String.t()
  def topic_for_table(table) when is_binary(table), do: "changes:#{table}"

  @impl GenServer
  def init(opts) do
    repo_config = Keyword.get(opts, :repo_config, MyApp.Repo.config())
    {:ok, pid} = Postgrex.Notifications.start_link(repo_config)
    {:ok, ref} = Postgrex.Notifications.listen(pid, @channel)
    Logger.info("[DataSync.ChangesetBroadcaster] Subscribed to channel '#{@channel}'")
    {:ok, %{notifier: pid, ref: ref}}
  end

  @impl GenServer
  def handle_info({:notification, _pid, _ref, @channel, payload}, state) do
    case parse_payload(payload) do
      {:ok, event} -> broadcast(event)
      {:error, reason} -> Logger.warning("[DataSync.ChangesetBroadcaster] Bad payload: #{reason}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp parse_payload(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         {:ok, table} <- fetch_string(decoded, "table"),
         {:ok, op_raw} <- fetch_string(decoded, "operation"),
         {:ok, operation} <- parse_operation(op_raw),
         {:ok, payload} <- fetch_map(decoded, "data") do
      {:ok, %{table: table, operation: operation, payload: payload}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, "missing or invalid field: #{key}"}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      v when is_map(v) -> {:ok, v}
      _ -> {:error, "missing or invalid field: #{key}"}
    end
  end

  defp parse_operation("INSERT"), do: {:ok, :insert}
  defp parse_operation("UPDATE"), do: {:ok, :update}
  defp parse_operation("DELETE"), do: {:ok, :delete}
  defp parse_operation(op), do: {:error, "unknown operation: #{op}"}

  defp broadcast(%{table: table} = event) do
    topic = topic_for_table(table)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:data_change, event})
  end
end
```
