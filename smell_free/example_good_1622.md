```elixir
defmodule Web.SseBroadcaster do
  @moduledoc """
  A supervised GenServer that manages active Server-Sent Events connections
  and broadcasts named events to individual connections or topic-based groups.
  Connections are tracked by a unique ID and automatically cleaned up on
  process exit.
  """

  use GenServer

  @type connection_id :: String.t()
  @type topic :: String.t()
  @type sse_event :: %{event: String.t(), data: map(), id: String.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(connection_id(), pid(), [topic()]) :: :ok
  def register(conn_id, pid, topics \\ []) when is_binary(conn_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, conn_id, pid, topics})
  end

  @spec unregister(connection_id()) :: :ok
  def unregister(conn_id) when is_binary(conn_id) do
    GenServer.cast(__MODULE__, {:unregister, conn_id})
  end

  @spec broadcast_to(connection_id(), sse_event()) :: :ok | {:error, :not_found}
  def broadcast_to(conn_id, event) when is_binary(conn_id) do
    GenServer.call(__MODULE__, {:send_to, conn_id, event})
  end

  @spec broadcast_topic(topic(), sse_event()) :: {:ok, non_neg_integer()}
  def broadcast_topic(topic, event) when is_binary(topic) do
    GenServer.call(__MODULE__, {:broadcast_topic, topic, event})
  end

  @spec broadcast_all(sse_event()) :: {:ok, non_neg_integer()}
  def broadcast_all(event) do
    GenServer.call(__MODULE__, {:broadcast_all, event})
  end

  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:count, topic})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{connections: %{}, topics: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:register, conn_id, pid, topics}, _from, state) do
    ref = Process.monitor(pid)
    conn = %{pid: pid, topics: topics}
    new_connections = Map.put(state.connections, conn_id, conn)
    new_monitors = Map.put(state.monitors, ref, conn_id)
    new_topics = Enum.reduce(topics, state.topics, fn t, acc ->
      Map.update(acc, t, MapSet.new([conn_id]), &MapSet.put(&1, conn_id))
    end)
    {:reply, :ok, %{state | connections: new_connections, topics: new_topics, monitors: new_monitors}}
  end

  def handle_call({:send_to, conn_id, event}, _from, state) do
    result = case Map.fetch(state.connections, conn_id) do
      {:ok, %{pid: pid}} ->
        send(pid, {:sse_event, format_event(event)})
        :ok
      :error ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  def handle_call({:broadcast_topic, topic, event}, _from, state) do
    conn_ids = Map.get(state.topics, topic, MapSet.new())
    count = send_to_many(conn_ids, state.connections, event)
    {:reply, {:ok, count}, state}
  end

  def handle_call({:broadcast_all, event}, _from, state) do
    conn_ids = MapSet.new(Map.keys(state.connections))
    count = send_to_many(conn_ids, state.connections, event)
    {:reply, {:ok, count}, state}
  end

  def handle_call({:count, topic}, _from, state) do
    count = state.topics |> Map.get(topic, MapSet.new()) |> MapSet.size()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:unregister, conn_id}, state) do
    {:noreply, drop_connection(conn_id, state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    new_state = case Map.fetch(state.monitors, ref) do
      {:ok, conn_id} ->
        drop_connection(conn_id, %{state | monitors: Map.delete(state.monitors, ref)})
      :error ->
        state
    end
    {:noreply, new_state}
  end

  @spec send_to_many(MapSet.t(), map(), sse_event()) :: non_neg_integer()
  defp send_to_many(conn_ids, connections, event) do
    formatted = format_event(event)
    Enum.reduce(conn_ids, 0, fn id, count ->
      case Map.fetch(connections, id) do
        {:ok, %{pid: pid}} -> send(pid, {:sse_event, formatted}); count + 1
        :error -> count
      end
    end)
  end

  @spec drop_connection(connection_id(), map()) :: map()
  defp drop_connection(conn_id, state) do
    case Map.fetch(state.connections, conn_id) do
      {:ok, %{topics: topics}} ->
        new_topics = Enum.reduce(topics, state.topics, fn t, acc ->
          Map.update(acc, t, MapSet.new(), &MapSet.delete(&1, conn_id))
        end)
        %{state | connections: Map.delete(state.connections, conn_id), topics: new_topics}
      :error ->
        state
    end
  end

  @spec format_event(sse_event()) :: String.t()
  defp format_event(%{event: name, data: data, id: id}) do
    parts = []
    parts = if id, do: ["id: #{id}" | parts], else: parts
    parts = ["event: #{name}" | parts]
    parts = ["data: #{Jason.encode!(data)}" | parts]
    Enum.reverse(parts) |> Enum.join("\n") |> Kernel.<>("\n\n")
  end
end
```
