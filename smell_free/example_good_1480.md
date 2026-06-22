```elixir
defmodule Warehouse.Inventory.StockSupervisor do
  @moduledoc """
  Supervises all dynamic stock worker processes for warehouse inventory tracking.
  Each SKU is managed by a dedicated `StockWorker` process under this supervisor.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Warehouse.Inventory.DynamicStockSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec start_worker(String.t()) :: DynamicSupervisor.on_start_child()
  def start_worker(sku) when is_binary(sku) do
    child_spec = {Warehouse.Inventory.StockWorker, sku: sku}
    DynamicSupervisor.start_child(Warehouse.Inventory.DynamicStockSupervisor, child_spec)
  end

  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(sku) when is_binary(sku) do
    case find_worker_pid(sku) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(Warehouse.Inventory.DynamicStockSupervisor, pid)
      {:error, :not_found} = error -> error
    end
  end

  @spec find_worker_pid(String.t()) :: {:ok, pid()} | {:error, :not_found}
  defp find_worker_pid(sku) do
    DynamicSupervisor.which_children(Warehouse.Inventory.DynamicStockSupervisor)
    |> Enum.find_value({:error, :not_found}, fn {_, pid, _, _} ->
      if Warehouse.Inventory.StockWorker.sku(pid) == sku, do: {:ok, pid}
    end)
  end
end

defmodule Warehouse.Inventory.StockWorker do
  @moduledoc """
  Manages real-time stock level state for a single SKU.
  Handles reservations, releases, and replenishment events.
  """

  use GenServer

  @type state :: %{sku: String.t(), available: non_neg_integer(), reserved: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sku = Keyword.fetch!(opts, :sku)
    GenServer.start_link(__MODULE__, sku, name: via_registry(sku))
  end

  @spec sku(pid()) :: String.t()
  def sku(pid), do: GenServer.call(pid, :get_sku)

  @spec reserve(String.t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, :insufficient_stock}
  def reserve(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    GenServer.call(via_registry(sku), {:reserve, quantity})
  end

  @spec release(String.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def release(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    GenServer.call(via_registry(sku), {:release, quantity})
  end

  @spec replenish(String.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def replenish(sku, quantity) when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    GenServer.call(via_registry(sku), {:replenish, quantity})
  end

  @spec stock_level(String.t()) :: {:ok, state()} | {:error, :not_found}
  def stock_level(sku) when is_binary(sku) do
    case Registry.lookup(Warehouse.Inventory.Registry, sku) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_state)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(sku) do
    {:ok, %{sku: sku, available: 0, reserved: 0}}
  end

  @impl GenServer
  def handle_call(:get_sku, _from, state), do: {:reply, state.sku, state}
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call({:reserve, quantity}, _from, state) do
    if state.available >= quantity do
      new_state = %{state | available: state.available - quantity, reserved: state.reserved + quantity}
      {:reply, {:ok, new_state.available}, new_state}
    else
      {:reply, {:error, :insufficient_stock}, state}
    end
  end

  def handle_call({:release, quantity}, _from, state) do
    released = min(quantity, state.reserved)
    new_state = %{state | reserved: state.reserved - released, available: state.available + released}
    {:reply, {:ok, new_state.available}, new_state}
  end

  def handle_call({:replenish, quantity}, _from, state) do
    new_state = %{state | available: state.available + quantity}
    {:reply, {:ok, new_state.available}, new_state}
  end

  @spec via_registry(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via_registry(sku), do: {:via, Registry, {Warehouse.Inventory.Registry, sku}}
end
```
