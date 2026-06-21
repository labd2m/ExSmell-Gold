# File: `example_good_03.md`

```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  GenServer that manages in-memory stock levels for a registry of SKUs,
  broadcasting level changes via Phoenix.PubSub on every mutation.

  State lives in this process; all reads and writes are serialized through
  the GenServer to guarantee consistency without external locking.
  """

  use GenServer

  require Logger

  @pubsub MyApp.PubSub
  @stock_topic "inventory:stock_levels"

  @type sku :: String.t()
  @type quantity :: non_neg_integer()
  @type stock :: %{sku() => quantity()}

  @doc false
  def start_link(initial_stock) when is_map(initial_stock) do
    GenServer.start_link(__MODULE__, initial_stock, name: __MODULE__)
  end

  @doc """
  Returns the current stock level for a given SKU.

  Returns `{:ok, quantity}` or `{:error, :unknown_sku}`.
  """
  @spec level(sku()) :: {:ok, quantity()} | {:error, :unknown_sku}
  def level(sku) when is_binary(sku) do
    GenServer.call(__MODULE__, {:level, sku})
  end

  @doc """
  Attempts to reserve `qty` units of the given SKU.

  Returns `:ok` on success, `{:error, :insufficient_stock}` when the
  current level is below `qty`, or `{:error, :unknown_sku}` for
  unregistered SKUs.
  """
  @spec reserve(sku(), pos_integer()) ::
          :ok | {:error, :insufficient_stock | :unknown_sku}
  def reserve(sku, qty) when is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.call(__MODULE__, {:reserve, sku, qty})
  end

  @doc """
  Increases the stock level of an existing SKU by `qty` units.

  Returns `:ok` or `{:error, :unknown_sku}`.
  """
  @spec restock(sku(), pos_integer()) :: :ok | {:error, :unknown_sku}
  def restock(sku, qty) when is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.call(__MODULE__, {:restock, sku, qty})
  end

  @doc """
  Registers a new SKU with an initial stock quantity.

  Returns `:ok` or `{:error, :already_registered}` if the SKU exists.
  """
  @spec register_sku(sku(), quantity()) :: :ok | {:error, :already_registered}
  def register_sku(sku, initial_qty)
      when is_binary(sku) and is_integer(initial_qty) and initial_qty >= 0 do
    GenServer.call(__MODULE__, {:register_sku, sku, initial_qty})
  end

  @doc """
  Returns a snapshot of all currently tracked SKUs and their quantities.
  """
  @spec snapshot() :: stock()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl GenServer
  def init(initial_stock), do: {:ok, initial_stock}

  @impl GenServer
  def handle_call({:level, sku}, _from, stock) do
    {:reply, fetch_level(stock, sku), stock}
  end

  @impl GenServer
  def handle_call({:reserve, sku, qty}, _from, stock) do
    {result, new_stock} = apply_reservation(stock, sku, qty)
    {:reply, result, new_stock}
  end

  @impl GenServer
  def handle_call({:restock, sku, qty}, _from, stock) do
    {result, new_stock} = apply_restock(stock, sku, qty)
    {:reply, result, new_stock}
  end

  @impl GenServer
  def handle_call({:register_sku, sku, qty}, _from, stock) do
    {result, new_stock} = apply_registration(stock, sku, qty)
    {:reply, result, new_stock}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, stock) do
    {:reply, stock, stock}
  end

  defp fetch_level(stock, sku) do
    case Map.fetch(stock, sku) do
      {:ok, qty} -> {:ok, qty}
      :error -> {:error, :unknown_sku}
    end
  end

  defp apply_reservation(stock, sku, qty) do
    case Map.fetch(stock, sku) do
      {:ok, current} when current >= qty ->
        new_qty = current - qty
        broadcast(sku, new_qty)
        {:ok, Map.put(stock, sku, new_qty)}

      {:ok, _current} ->
        {{:error, :insufficient_stock}, stock}

      :error ->
        {{:error, :unknown_sku}, stock}
    end
  end

  defp apply_restock(stock, sku, qty) do
    case Map.fetch(stock, sku) do
      {:ok, current} ->
        new_qty = current + qty
        broadcast(sku, new_qty)
        {:ok, Map.put(stock, sku, new_qty)}

      :error ->
        {{:error, :unknown_sku}, stock}
    end
  end

  defp apply_registration(stock, sku, qty) do
    if Map.has_key?(stock, sku) do
      {{:error, :already_registered}, stock}
    else
      {:ok, Map.put(stock, sku, qty)}
    end
  end

  defp broadcast(sku, new_qty) do
    Phoenix.PubSub.broadcast(@pubsub, @stock_topic, {:stock_updated, sku, new_qty})
  end
end
```
