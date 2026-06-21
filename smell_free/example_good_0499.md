```elixir
defmodule AppWeb.HeartbeatMonitor do
  @moduledoc """
  A GenServer that tracks liveness of WebSocket or Channel connections by
  monitoring periodic heartbeat messages.

  Each connection registers with a unique ID. The monitor sends a configurable
  ping interval and evicts connections that fail to respond within the deadline.
  Eviction callbacks notify the caller so sessions can be cleaned up.
  """

  use GenServer

  require Logger

  @type connection_id :: String.t()
  @type eviction_callback :: (connection_id() -> :ok)
  @type connection_entry :: %{
          id: connection_id(),
          last_seen: integer(),
          deadline_ms: pos_integer(),
          on_evict: eviction_callback()
        }

  @default_deadline_ms :timer.seconds(60)
  @check_interval_ms :timer.seconds(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a connection for heartbeat monitoring.
  `on_evict` is called with the connection id when it is evicted for inactivity.
  """
  @spec register(connection_id(), keyword()) :: :ok
  def register(connection_id, opts \\ []) when is_binary(connection_id) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    on_evict = Keyword.get(opts, :on_evict, fn _id -> :ok end)
    GenServer.cast(__MODULE__, {:register, connection_id, deadline_ms, on_evict})
  end

  @doc "Records a heartbeat for `connection_id`, resetting its liveness timer."
  @spec heartbeat(connection_id()) :: :ok
  def heartbeat(connection_id) when is_binary(connection_id) do
    GenServer.cast(__MODULE__, {:heartbeat, connection_id})
  end

  @doc "Explicitly deregisters a connection that has cleanly disconnected."
  @spec deregister(connection_id()) :: :ok
  def deregister(connection_id) when is_binary(connection_id) do
    GenServer.cast(__MODULE__, {:deregister, connection_id})
  end

  @doc "Returns the count of currently monitored connections."
  @spec connection_count() :: non_neg_integer()
  def connection_count, do: GenServer.call(__MODULE__, :connection_count)

  @impl GenServer
  def init(_opts) do
    schedule_check()
    {:ok, %{connections: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, id, deadline_ms, on_evict}, state) do
    entry = %{id: id, last_seen: now_ms(), deadline_ms: deadline_ms, on_evict: on_evict}
    {:noreply, put_in(state, [:connections, id], entry)}
  end

  @impl GenServer
  def handle_cast({:heartbeat, id}, state) do
    new_state = update_in(state, [:connections, id], fn
      nil -> nil
      entry -> %{entry | last_seen: now_ms()}
    end)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:deregister, id}, state) do
    {:noreply, %{state | connections: Map.delete(state.connections, id)}}
  end

  @impl GenServer
  def handle_call(:connection_count, _from, state) do
    {:reply, map_size(state.connections), state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    schedule_check()
    {:noreply, evict_stale(state)}
  end

  defp evict_stale(%{connections: connections} = state) do
    current = now_ms()

    {stale, active} =
      Enum.split_with(connections, fn {_id, entry} ->
        current - entry.last_seen > entry.deadline_ms
      end)

    Enum.each(stale, fn {id, entry} ->
      Logger.info("[HeartbeatMonitor] Evicting stale connection", id: id)
      entry.on_evict.(id)
    end)

    %{state | connections: Map.new(active)}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval_ms)
  defp now_ms, do: :erlang.system_time(:millisecond)
end
```
