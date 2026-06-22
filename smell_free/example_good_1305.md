**File:** `example_good_1305.md`

```elixir
defmodule ConnectionPool.Worker do
  @moduledoc """
  A GenServer managing a single connection to an external service.
  Reports its availability via a Registry key for pool routing.
  """

  use GenServer

  @enforce_keys [:id, :connect_fn]
  defstruct [:id, :connect_fn, :connection, :checked_out_at]

  @type t :: %__MODULE__{
          id: String.t(),
          connect_fn: (-> {:ok, term()} | {:error, term()}),
          connection: term(),
          checked_out_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @spec checkout(String.t()) :: {:ok, term()} | {:error, :busy} | {:error, :unavailable}
  def checkout(worker_id) when is_binary(worker_id) do
    GenServer.call(via(worker_id), :checkout)
  end

  @spec checkin(String.t()) :: :ok
  def checkin(worker_id) when is_binary(worker_id) do
    GenServer.cast(via(worker_id), :checkin)
  end

  @spec available?(String.t()) :: boolean()
  def available?(worker_id) when is_binary(worker_id) do
    case Registry.lookup(ConnectionPool.Registry, {worker_id, :available}) do
      [_] -> true
      [] -> false
    end
  end

  @impl GenServer
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    connect_fn = Keyword.fetch!(opts, :connect_fn)

    case connect_fn.() do
      {:ok, connection} ->
        register_available(id)
        {:ok, %__MODULE__{id: id, connect_fn: connect_fn, connection: connection}}

      {:error, reason} ->
        {:stop, {:connection_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:checkout, _from, %__MODULE__{checked_out_at: nil} = state) do
    Registry.unregister(ConnectionPool.Registry, {state.id, :available})
    {:reply, {:ok, state.connection}, %{state | checked_out_at: System.monotonic_time(:millisecond)}}
  end

  def handle_call(:checkout, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl GenServer
  def handle_cast(:checkin, %__MODULE__{} = state) do
    register_available(state.id)
    {:noreply, %{state | checked_out_at: nil}}
  end

  defp register_available(id) do
    Registry.register(ConnectionPool.Registry, {id, :available}, true)
  end

  defp via(id), do: {:via, Registry, {ConnectionPool.Registry, id}}
end

defmodule ConnectionPool do
  @moduledoc """
  Manages a supervised pool of reusable connections.
  Routes checkout requests to available workers via Registry lookup.
  """

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    ConnectionPool.Supervisor.start_link(opts)
  end

  @spec checkout() :: {:ok, {String.t(), term()}} | {:error, :pool_exhausted}
  def checkout do
    available = find_available_worker()

    case available do
      nil ->
        {:error, :pool_exhausted}

      worker_id ->
        case ConnectionPool.Worker.checkout(worker_id) do
          {:ok, conn} -> {:ok, {worker_id, conn}}
          {:error, _} -> checkout()
        end
    end
  end

  @spec checkin(String.t()) :: :ok
  def checkin(worker_id) when is_binary(worker_id) do
    ConnectionPool.Worker.checkin(worker_id)
  end

  defp find_available_worker do
    ConnectionPool.Registry
    |> Registry.select([{{{:"$1", :available}, :_, :_}, [], [:"$1"]}])
    |> List.first()
  end
end

defmodule ConnectionPool.Supervisor do
  @moduledoc "Supervises the pool's Registry and worker processes."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, 5)
    connect_fn = Keyword.fetch!(opts, :connect_fn)

    workers =
      Enum.map(1..pool_size, fn i ->
        id = "worker_#{i}"
        Supervisor.child_spec({ConnectionPool.Worker, id: id, connect_fn: connect_fn}, id: id)
      end)

    children = [
      {Registry, keys: :duplicate, name: ConnectionPool.Registry}
      | workers
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
