```elixir
defmodule Warehouse.Inventory.StockSupervisor do
  @moduledoc """
  Supervises one `StockWorker` process per warehouse zone.
  Workers are started dynamically and linked into the supervision tree.
  """

  use Supervisor

  @doc """
  Starts the StockSupervisor linked to the current process.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a supervised worker for the given zone identifier.
  """
  @spec start_zone_worker(String.t()) :: DynamicSupervisor.on_start_child()
  def start_zone_worker(zone_id) when is_binary(zone_id) do
    child_spec = Warehouse.Inventory.StockWorker.child_spec(zone_id: zone_id)
    DynamicSupervisor.start_child(__MODULE__.Dynamic, child_spec)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: __MODULE__.Dynamic, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Warehouse.Inventory.StockWorker do
  @moduledoc """
  Maintains the live stock count for a single warehouse zone.
  All mutations go through this process to guarantee sequential consistency.
  """

  use GenServer

  @type state :: %{zone_id: String.t(), stock: non_neg_integer()}

  @doc """
  Returns a child spec for starting this worker under a supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    zone_id = Keyword.fetch!(opts, :zone_id)

    %{
      id: {__MODULE__, zone_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Starts a StockWorker linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_id = Keyword.fetch!(opts, :zone_id)
    GenServer.start_link(__MODULE__, %{zone_id: zone_id, stock: 0}, name: via(zone_id))
  end

  @doc """
  Returns the current stock level for the zone.
  """
  @spec current_stock(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def current_stock(zone_id) when is_binary(zone_id) do
    case Registry.lookup(Warehouse.Registry, zone_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :current_stock)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Adjusts stock by `delta`. Negative values reduce stock; returns error if stock would go below zero.
  """
  @spec adjust(String.t(), integer()) :: :ok | {:error, :insufficient_stock | :not_found}
  def adjust(zone_id, delta) when is_binary(zone_id) and is_integer(delta) do
    case Registry.lookup(Warehouse.Registry, zone_id) do
      [{pid, _}] -> GenServer.call(pid, {:adjust, delta})
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:current_stock, _from, state) do
    {:reply, state.stock, state}
  end

  @impl GenServer
  def handle_call({:adjust, delta}, _from, state) do
    new_stock = state.stock + delta

    if new_stock < 0 do
      {:reply, {:error, :insufficient_stock}, state}
    else
      {:reply, :ok, %{state | stock: new_stock}}
    end
  end

  defp via(zone_id), do: {:via, Registry, {Warehouse.Registry, zone_id}}
end
```
