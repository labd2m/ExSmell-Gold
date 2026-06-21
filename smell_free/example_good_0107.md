```elixir
defmodule Inventory.StockLedger do
  @moduledoc """
  A GenServer that maintains per-SKU stock levels as an in-memory ledger.
  Adjustments are applied atomically inside the server process, preventing
  race conditions that would arise from concurrent direct database reads.
  The ledger is bootstrapped from the database on startup and writes
  adjustments through to the persistence layer on every mutation.
  """

  use GenServer

  require Logger

  alias Inventory.Repo
  alias Inventory.StockEntry

  @type sku :: String.t()
  @type quantity :: non_neg_integer()

  @doc "Starts the ledger and bootstraps state from the database."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current on-hand quantity for `sku`."
  @spec on_hand(sku()) :: {:ok, quantity()} | {:error, :unknown_sku}
  def on_hand(sku) when is_binary(sku) do
    GenServer.call(__MODULE__, {:on_hand, sku})
  end

  @doc "Increases on-hand quantity for `sku` by `amount`. Amount must be positive."
  @spec receive_stock(sku(), pos_integer()) :: :ok | {:error, :unknown_sku}
  def receive_stock(sku, amount) when is_binary(sku) and is_integer(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:adjust, sku, amount})
  end

  @doc """
  Decreases on-hand quantity for `sku` by `amount`.
  Returns `{:error, :insufficient_stock}` when the result would go negative.
  """
  @spec reserve(sku(), pos_integer()) ::
          :ok | {:error, :unknown_sku | :insufficient_stock}
  def reserve(sku, amount) when is_binary(sku) and is_integer(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:reserve, sku, amount})
  end

  @impl GenServer
  def init(_opts) do
    stock_map = load_stock_from_db()
    Logger.info("[Inventory.StockLedger] Loaded #{map_size(stock_map)} SKU(s) from database")
    {:ok, stock_map}
  end

  @impl GenServer
  def handle_call({:on_hand, sku}, _from, stock) do
    result =
      case Map.get(stock, sku) do
        nil -> {:error, :unknown_sku}
        qty -> {:ok, qty}
      end

    {:reply, result, stock}
  end

  def handle_call({:adjust, sku, amount}, _from, stock) do
    case Map.get(stock, sku) do
      nil ->
        {:reply, {:error, :unknown_sku}, stock}

      qty ->
        new_qty = qty + amount
        persist_adjustment(sku, new_qty)
        {:reply, :ok, Map.put(stock, sku, new_qty)}
    end
  end

  def handle_call({:reserve, sku, amount}, _from, stock) do
    case Map.get(stock, sku) do
      nil ->
        {:reply, {:error, :unknown_sku}, stock}

      qty when qty < amount ->
        {:reply, {:error, :insufficient_stock}, stock}

      qty ->
        new_qty = qty - amount
        persist_adjustment(sku, new_qty)
        {:reply, :ok, Map.put(stock, sku, new_qty)}
    end
  end

  defp load_stock_from_db do
    Repo.all(StockEntry)
    |> Map.new(fn %StockEntry{sku: sku, quantity: qty} -> {sku, qty} end)
  end

  defp persist_adjustment(sku, new_qty) do
    Repo.update_all(
      {StockEntry, sku: sku},
      set: [quantity: new_qty, updated_at: DateTime.utc_now()]
    )
  end
end
```
