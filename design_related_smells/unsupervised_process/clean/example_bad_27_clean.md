```elixir
defmodule WarehouseStock do
  use GenServer

  @moduledoc """
  Maintains live stock levels for a single warehouse location.
  Handles reservations, releases, and restocking events.
  """

  defstruct [:warehouse_id, :location, stock: %{}, reservations: %{}]

  def start(%{warehouse_id: id, location: location}) do
    GenServer.start(__MODULE__, %{warehouse_id: id, location: location}, name: via(id))
  end

  def restock(warehouse_id, sku, quantity) do
    GenServer.call(via(warehouse_id), {:restock, sku, quantity})
  end

  def reserve(warehouse_id, order_id, sku, quantity) do
    GenServer.call(via(warehouse_id), {:reserve, order_id, sku, quantity})
  end

  def release(warehouse_id, order_id) do
    GenServer.call(via(warehouse_id), {:release, order_id})
  end

  def commit(warehouse_id, order_id) do
    GenServer.call(via(warehouse_id), {:commit, order_id})
  end

  def available(warehouse_id, sku) do
    GenServer.call(via(warehouse_id), {:available, sku})
  end

  def snapshot(warehouse_id) do
    GenServer.call(via(warehouse_id), :snapshot)
  end

  defp via(id), do: {:via, Registry, {WarehouseRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{warehouse_id: id, location: location}) do
    {:ok, %__MODULE__{warehouse_id: id, location: location}}
  end

  @impl true
  def handle_call({:restock, sku, qty}, _from, state) do
    stock = Map.update(state.stock, sku, qty, &(&1 + qty))
    {:reply, {:ok, Map.get(stock, sku)}, %{state | stock: stock}}
  end

  def handle_call({:reserve, order_id, sku, qty}, _from, state) do
    available = Map.get(state.stock, sku, 0)

    if available >= qty do
      stock = Map.update!(state.stock, sku, &(&1 - qty))
      reservations = Map.put(state.reservations, order_id, %{sku: sku, quantity: qty})
      {:reply, :ok, %{state | stock: stock, reservations: reservations}}
    else
      {:reply, {:error, :insufficient_stock}, state}
    end
  end

  def handle_call({:release, order_id}, _from, state) do
    case Map.pop(state.reservations, order_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {%{sku: sku, quantity: qty}, reservations} ->
        stock = Map.update(state.stock, sku, qty, &(&1 + qty))
        {:reply, :ok, %{state | stock: stock, reservations: reservations}}
    end
  end

  def handle_call({:commit, order_id}, _from, state) do
    {_, reservations} = Map.pop(state.reservations, order_id)
    {:reply, :ok, %{state | reservations: reservations}}
  end

  def handle_call({:available, sku}, _from, state) do
    {:reply, Map.get(state.stock, sku, 0), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, %{stock: state.stock, reservations: state.reservations}, state}
  end
end

defmodule InventoryManager do
  @moduledoc "Manages multiple warehouse stock processes."

  def open_warehouse(attrs) do
    case WarehouseStock.start(attrs) do
      {:ok, _pid} -> {:ok, attrs.warehouse_id}
      {:error, {:already_started, _}} -> {:ok, attrs.warehouse_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def transfer_stock(from_id, to_id, sku, qty) do
    with :ok <- WarehouseStock.reserve(from_id, :transfer, sku, qty),
         :ok <- WarehouseStock.restock(to_id, sku, qty),
         :ok <- WarehouseStock.commit(from_id, :transfer) do
      :ok
    else
      {:error, reason} ->
        WarehouseStock.release(from_id, :transfer)
        {:error, reason}
    end
  end
end
```
