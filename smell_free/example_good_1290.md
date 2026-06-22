```elixir
defmodule Infra.ConnectionPool do
  @moduledoc """
  A bounded GenServer-managed pool for reusable connection resources.

  Connections are checked out by callers and returned when done. If the pool
  is exhausted, callers block up to a configurable timeout before receiving
  `{:error, :timeout}`. Connections that crash while checked out are
  automatically replaced.
  """

  use GenServer

  require Logger

  alias Infra.ConnectionPool.{Config, State, Connection}

  @doc false
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  @doc """
  Checks out a connection from the pool, blocking up to `timeout_ms` if empty.
  """
  @spec checkout(atom(), pos_integer()) :: {:ok, Connection.t()} | {:error, :timeout}
  def checkout(pool_name, timeout_ms \\ 5_000)
      when is_atom(pool_name) and is_integer(timeout_ms) and timeout_ms > 0 do
    try do
      GenServer.call(pool_name, :checkout, timeout_ms)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Returns a connection to the pool for reuse.
  """
  @spec checkin(atom(), Connection.t()) :: :ok
  def checkin(pool_name, %Connection{} = conn) when is_atom(pool_name) do
    GenServer.cast(pool_name, {:checkin, conn})
  end

  @doc """
  Returns pool statistics: idle, checked-out, and total connection counts.
  """
  @spec stats(atom()) :: map()
  def stats(pool_name) when is_atom(pool_name) do
    GenServer.call(pool_name, :stats)
  end

  @impl GenServer
  def init(%Config{size: size, factory: factory} = config) do
    Process.flag(:trap_exit, true)
    connections = Enum.map(1..size, fn _ -> factory.() end)
    state = State.new(connections)
    {:ok, %{state: state, config: config}}
  end

  @impl GenServer
  def handle_call(:checkout, from, %{state: state} = s) do
    case State.checkout(state) do
      {:ok, conn, new_state} ->
        ref = Process.monitor(elem(from, 0))
        {:reply, {:ok, conn}, %{s | state: State.track_caller(new_state, ref, conn)}}

      :empty ->
        {:noreply, %{s | state: State.enqueue_waiter(state, from)}}
    end
  end

  def handle_call(:stats, _from, %{state: state} = s) do
    {:reply, State.stats(state), s}
  end

  @impl GenServer
  def handle_cast({:checkin, conn}, %{state: state, config: config} = s) do
    case State.dequeue_waiter(state) do
      {:ok, from, new_state} ->
        GenServer.reply(from, {:ok, conn})
        {:noreply, %{s | state: new_state}}

      :empty ->
        {:noreply, %{s | state: State.checkin(state, conn)}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{state: state, config: config} = s) do
    new_state =
      case State.release_by_ref(state, ref) do
        {:ok, updated} ->
          new_conn = config.factory.()
          State.checkin(updated, new_conn)

        :not_found ->
          state
      end

    {:noreply, %{s | state: new_state}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Infra.ConnectionPool.Config do
  @moduledoc false

  @enforce_keys [:name, :size, :factory]
  defstruct [:name, :size, :factory]

  @type t :: %__MODULE__{name: atom(), size: pos_integer(), factory: (() -> Connection.t())}
end

defmodule Infra.ConnectionPool.Connection do
  @moduledoc false

  @enforce_keys [:id, :resource]
  defstruct [:id, :resource]

  @type t :: %__MODULE__{id: String.t(), resource: term()}
end

defmodule Infra.ConnectionPool.State do
  @moduledoc false

  alias Infra.ConnectionPool.Connection

  defstruct idle: [], checked_out: %{}, waiters: :queue.new()

  @type t :: %__MODULE__{}

  def new(conns), do: %__MODULE__{idle: conns}

  def checkout(%__MODULE__{idle: [conn | rest]} = s) do
    {:ok, conn, %{s | idle: rest, checked_out: Map.put(s.checked_out, conn.id, conn)}}
  end

  def checkout(%__MODULE__{idle: []}), do: :empty

  def checkin(%__MODULE__{idle: idle} = s, conn), do: %{s | idle: [conn | idle]}

  def track_caller(%__MODULE__{} = s, ref, conn) do
    %{s | checked_out: Map.put(s.checked_out, ref, conn)}
  end

  def release_by_ref(%__MODULE__{checked_out: co} = s, ref) do
    case Map.pop(co, ref) do
      {nil, _} -> :not_found
      {_conn, updated} -> {:ok, %{s | checked_out: updated}}
    end
  end

  def enqueue_waiter(%__MODULE__{waiters: q} = s, from) do
    %{s | waiters: :queue.in(from, q)}
  end

  def dequeue_waiter(%__MODULE__{waiters: q} = s) do
    case :queue.out(q) do
      {{:value, from}, rest} -> {:ok, from, %{s | waiters: rest}}
      {:empty, _} -> :empty
    end
  end

  def stats(%__MODULE__{idle: idle, checked_out: co}) do
    %{idle: length(idle), checked_out: map_size(co), total: length(idle) + map_size(co)}
  end
end
```
