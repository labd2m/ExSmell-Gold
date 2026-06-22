```elixir
defmodule Warehouse.Inventory.StockSupervisor do
  @moduledoc """
  Supervises per-product stock-tracking workers. Each product gets its own
  supervised `StockWorker` process that manages inventory state. Workers are
  started on demand and remain alive for the lifetime of the application.
  """

  use Supervisor

  alias Warehouse.Inventory.StockWorker

  @doc """
  Starts the supervisor and links it to the calling process.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Ensures a `StockWorker` is running for the given product ID.
  Returns `{:ok, pid}` if started or already running.
  """
  @spec ensure_worker(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_worker(product_id) when is_binary(product_id) do
    case Supervisor.start_child(__MODULE__, worker_spec(product_id)) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Supervisor
  def init(_init_arg) do
    Supervisor.init([], strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec worker_spec(String.t()) :: Supervisor.child_spec()
  defp worker_spec(product_id) do
    %{
      id: {StockWorker, product_id},
      start: {StockWorker, :start_link, [[product_id: product_id]]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end
end

defmodule Warehouse.Inventory.StockWorker do
  @moduledoc """
  Manages the in-memory stock level for a single product. Provides
  a clean API for reserving, releasing, and querying stock quantities.
  """

  use GenServer

  @type state :: %{product_id: String.t(), quantity: non_neg_integer(), reserved: non_neg_integer()}

  @doc "Starts a StockWorker linked to the supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    product_id = Keyword.fetch!(opts, :product_id)
    GenServer.start_link(__MODULE__, product_id, name: via(product_id))
  end

  @doc "Returns the current available stock for a product."
  @spec available(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def available(product_id) when is_binary(product_id) do
    case Registry.lookup(Warehouse.Registry, product_id) do
      [{pid, _}] -> GenServer.call(pid, :available)
      [] -> {:error, :not_found}
    end
  end

  @doc "Reserves `quantity` units. Returns error if insufficient stock."
  @spec reserve(String.t(), pos_integer()) :: :ok | {:error, :insufficient_stock | :not_found}
  def reserve(product_id, quantity)
      when is_binary(product_id) and is_integer(quantity) and quantity > 0 do
    case Registry.lookup(Warehouse.Registry, product_id) do
      [{pid, _}] -> GenServer.call(pid, {:reserve, quantity})
      [] -> {:error, :not_found}
    end
  end

  @doc "Releases previously reserved units back to available stock."
  @spec release(String.t(), pos_integer()) :: :ok | {:error, :not_found}
  def release(product_id, quantity)
      when is_binary(product_id) and is_integer(quantity) and quantity > 0 do
    case Registry.lookup(Warehouse.Registry, product_id) do
      [{pid, _}] -> GenServer.cast(pid, {:release, quantity})
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(product_id) do
    {:ok, %{product_id: product_id, quantity: 0, reserved: 0}}
  end

  @impl GenServer
  def handle_call(:available, _from, state) do
    available = state.quantity - state.reserved
    {:reply, {:ok, available}, state}
  end

  def handle_call({:reserve, quantity}, _from, state) do
    available = state.quantity - state.reserved

    if available >= quantity do
      {:reply, :ok, %{state | reserved: state.reserved + quantity}}
    else
      {:reply, {:error, :insufficient_stock}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, quantity}, state) do
    new_reserved = max(0, state.reserved - quantity)
    {:noreply, %{state | reserved: new_reserved}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via(product_id), do: {:via, Registry, {Warehouse.Registry, product_id}}
end
```
