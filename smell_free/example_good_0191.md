```elixir
defmodule Platform.ConnectionPool do
  @moduledoc """
  A GenServer-managed connection pool with blocking checkout and automatic
  checkin on caller process exit.

  Free connections are stored in ETS for direct-access reads. The GenServer
  serializes checkout and checkin operations and monitors each borrower,
  returning connections to the pool when a caller process exits unexpectedly.
  """

  use GenServer

  require Logger

  @type connection :: pid()
  @type checkout_result :: {:ok, connection()} | {:error, :pool_exhausted | :timeout}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Checks out a connection from the pool. Blocks up to `timeout_ms` if no
  connection is immediately available. Returns `{:error, :pool_exhausted}`
  if the wait elapses.
  """
  @spec checkout(GenServer.server(), pos_integer()) :: checkout_result()
  def checkout(server \\ __MODULE__, timeout_ms \\ 5_000) do
    GenServer.call(server, {:checkout, self()}, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Returns a previously checked-out connection to the pool.
  The connection must have been issued to the calling process.
  """
  @spec checkin(GenServer.server(), connection()) :: :ok | {:error, :not_owner}
  def checkin(server \\ __MODULE__, conn) do
    GenServer.call(server, {:checkin, conn, self()})
  end

  @doc "Returns current pool statistics."
  @spec stats(GenServer.server()) :: %{free: non_neg_integer(), checked_out: non_neg_integer(), capacity: pos_integer()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    connect_fn = Keyword.fetch!(opts, :connect_fn)
    table = :ets.new(:connection_pool, [:set, :private])

    connections = Enum.map(1..capacity, fn _i ->
      case connect_fn.() do
        {:ok, conn} -> conn
        {:error, reason} -> raise "Failed to open connection: #{inspect(reason)}"
      end
    end)

    state = %{
      free: :queue.from_list(connections),
      checked_out: %{},
      monitors: %{},
      capacity: capacity,
      connect_fn: connect_fn,
      table: table,
      waiters: :queue.new()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, caller}, from, state) do
    case :queue.out(state.free) do
      {{:value, conn}, remaining_free} ->
        monitor_ref = Process.monitor(caller)
        new_state = state
          |> Map.put(:free, remaining_free)
          |> put_in([:checked_out, conn], %{caller: caller, monitor_ref: monitor_ref})
          |> put_in([:monitors, monitor_ref], conn)
        {:reply, {:ok, conn}, new_state}

      {:empty, _} ->
        new_state = %{state | waiters: :queue.in(from, state.waiters)}
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_call({:checkin, conn, caller}, _from, state) do
    case Map.get(state.checked_out, conn) do
      %{caller: ^caller, monitor_ref: mref} ->
        Process.demonitor(mref, [:flush])
        new_state = return_connection(state, conn, mref)
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{
      free: :queue.len(state.free),
      checked_out: map_size(state.checked_out),
      capacity: state.capacity
    }
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      nil -> {:noreply, state}
      conn ->
        Logger.debug("[ConnectionPool] Auto-returning connection after caller exit")
        new_state = return_connection(state, conn, monitor_ref)
        {:noreply, new_state}
    end
  end

  defp return_connection(state, conn, monitor_ref) do
    clean_state = state
      |> update_in([:checked_out], &Map.delete(&1, conn))
      |> update_in([:monitors], &Map.delete(&1, monitor_ref))

    case :queue.out(clean_state.waiters) do
      {{:value, waiter}, remaining_waiters} ->
        waiter_monitor = Process.monitor(elem(waiter, 0))
        GenServer.reply(waiter, {:ok, conn})
        clean_state
          |> Map.put(:waiters, remaining_waiters)
          |> put_in([:checked_out, conn], %{caller: elem(waiter, 0), monitor_ref: waiter_monitor})
          |> put_in([:monitors, waiter_monitor], conn)

      {:empty, _} ->
        %{clean_state | free: :queue.in(conn, clean_state.free)}
    end
  end
end
```
