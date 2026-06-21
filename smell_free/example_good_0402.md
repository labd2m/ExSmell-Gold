```elixir
defmodule Network.ConnectionPool do
  @moduledoc """
  A bounded connection pool GenServer that manages a fixed number of
  pre-opened connections to an external resource. Callers check out a
  connection for exclusive use and check it back in when done. Requests
  that arrive when the pool is exhausted are queued with a configurable
  timeout so they are served as soon as a connection becomes available.
  """

  use GenServer

  require Logger

  @type connection :: pid()
  @type checkout_result :: {:ok, connection()} | {:error, :timeout}
  @type pool_state :: %{
          available: [connection()],
          in_use: MapSet.t(),
          waiting: :queue.queue()
        }

  @default_checkout_timeout_ms 5_000

  @doc "Starts the pool with `size` connections using `connect_fn` to open each one."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Checks out a connection from the pool. Blocks up to `timeout_ms` if empty."
  @spec checkout(GenServer.server(), pos_integer()) :: checkout_result()
  def checkout(server \ __MODULE__, timeout_ms \ @default_checkout_timeout_ms) do
    GenServer.call(server, {:checkout, self()}, timeout_ms + 100)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Returns a connection to the pool."
  @spec checkin(GenServer.server(), connection()) :: :ok
  def checkin(server \ __MODULE__, conn) when is_pid(conn) do
    GenServer.cast(server, {:checkin, conn})
  end

  @doc "Returns pool depth stats."
  @spec stats(GenServer.server()) :: %{available: non_neg_integer(), in_use: non_neg_integer(), waiting: non_neg_integer()}
  def stats(server \ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl GenServer
  def init(opts) do
    size = Keyword.get(opts, :size, 5)
    connect_fn = Keyword.fetch!(opts, :connect_fn)
    conns = Enum.map(1..size, fn _ -> connect_fn.() end)
    state = %{available: conns, in_use: MapSet.new(), waiting: :queue.new()}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, caller}, from, %{available: [conn | rest]} = state) do
    ref = Process.monitor(caller)
    new_state = %{state | available: rest, in_use: MapSet.put(state.in_use, {conn, ref})}
    {:reply, {:ok, conn}, new_state}
  end

  def handle_call({:checkout, caller}, from, %{available: []} = state) do
    timeout_ref = Process.send_after(self(), {:checkout_timeout, from}, @default_checkout_timeout_ms)
    entry = {from, caller, timeout_ref}
    {:noreply, %{state | waiting: :queue.in(entry, state.waiting)}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      available: length(state.available),
      in_use: MapSet.size(state.in_use),
      waiting: :queue.len(state.waiting)
    }
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:checkin, conn}, state) do
    new_in_use = state.in_use |> Enum.reject(fn {c, _ref} -> c == conn end) |> MapSet.new()
    {:noreply, dispatch_or_park(conn, %{state | in_use: new_in_use})}
  end

  @impl GenServer
  def handle_info({:checkout_timeout, from}, state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp dispatch_or_park(conn, %{waiting: q} = state) do
    case :queue.out(q) do
      {{:value, {from, _caller, timeout_ref}}, rest} ->
        Process.cancel_timer(timeout_ref)
        GenServer.reply(from, {:ok, conn})
        %{state | waiting: rest}

      {:empty, _} ->
        %{state | available: [conn | state.available]}
    end
  end
end
```
