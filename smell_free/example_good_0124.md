```elixir
defmodule MyApp.Inventory.StockLevel do
  @moduledoc """
  A GenServer that tracks real-time inventory levels for a single SKU.
  Write operations (reservations, releases, adjustments) are serialized
  through the process to prevent race conditions. Read operations are
  handled via `call` so the caller gets a consistent snapshot.

  Each `StockLevel` process is started on demand by
  `MyApp.Inventory.Registry` and registered under its SKU for fast lookup.
  """

  use GenServer

  require Logger

  @type sku :: String.t()
  @type quantity :: non_neg_integer()

  @type state :: %{
          sku: sku(),
          on_hand: quantity(),
          reserved: quantity(),
          reorder_point: quantity()
        }

  @doc "Starts a stock level process for the given SKU."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    sku = Keyword.fetch!(opts, :sku)
    GenServer.start_link(__MODULE__, opts, name: via(sku))
  end

  @doc "Returns the current on-hand and available quantities for a SKU."
  @spec snapshot(sku()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(sku) when is_binary(sku) do
    case Registry.lookup(MyApp.Inventory.Registry, sku) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :snapshot)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Reserves `qty` units of a SKU for a pending order.
  Returns `{:error, :insufficient_stock}` if available stock is too low.
  """
  @spec reserve(sku(), quantity()) :: :ok | {:error, :insufficient_stock}
  def reserve(sku, qty) when is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.call(via(sku), {:reserve, qty})
  end

  @doc "Releases a previously placed reservation of `qty` units."
  @spec release(sku(), quantity()) :: :ok
  def release(sku, qty) when is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.cast(via(sku), {:release, qty})
  end

  @doc "Applies a physical stock adjustment (positive or negative)."
  @spec adjust(sku(), integer()) :: :ok
  def adjust(sku, delta) when is_binary(sku) and is_integer(delta) do
    GenServer.cast(via(sku), {:adjust, delta})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      sku: Keyword.fetch!(opts, :sku),
      on_hand: Keyword.get(opts, :on_hand, 0),
      reserved: 0,
      reorder_point: Keyword.get(opts, :reorder_point, 10)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    reply = %{
      sku: state.sku,
      on_hand: state.on_hand,
      reserved: state.reserved,
      available: available(state)
    }

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:reserve, qty}, _from, state) do
    if available(state) >= qty do
      new_state = %{state | reserved: state.reserved + qty}
      maybe_log_low_stock(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :insufficient_stock}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, qty}, state) do
    released = max(state.reserved - qty, 0)
    {:noreply, %{state | reserved: released}}
  end

  @impl GenServer
  def handle_cast({:adjust, delta}, state) do
    new_on_hand = max(state.on_hand + delta, 0)
    new_state = %{state | on_hand: new_on_hand}
    maybe_log_low_stock(new_state)
    {:noreply, new_state}
  end

  @spec available(state()) :: quantity()
  defp available(state), do: max(state.on_hand - state.reserved, 0)

  @spec maybe_log_low_stock(state()) :: :ok
  defp maybe_log_low_stock(state) do
    if available(state) <= state.reorder_point do
      Logger.warning("inventory_low_stock",
        sku: state.sku,
        available: available(state),
        reorder_point: state.reorder_point
      )
    end

    :ok
  end

  @spec via(sku()) :: {:via, Registry, {MyApp.Inventory.Registry, sku()}}
  defp via(sku), do: {:via, Registry, {MyApp.Inventory.Registry, sku}}
end
```
