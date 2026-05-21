# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `StockAvailability` module — entire GenServer structure |
| **Affected function(s)** | `check/2`, `can_fulfill?/3`, `reserved_quantity/2`, `available_quantity/2` |
| **Short explanation** | The availability calculations performed here are pure arithmetic over an inventory snapshot passed in as a parameter. The snapshot is not stored in the process — it is supplied by the caller on each request. There is no shared mutable state and no reason to route these computations through a single process. |

```elixir
defmodule Inventory.StockAvailability do
  use GenServer

  @moduledoc """
  Computes real-time stock availability from inventory snapshots.
  Used by the order-placement service to confirm whether requested
  quantities can be fulfilled from current warehouse stock.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because the availability checks are pure
  # arithmetic over data passed in on each call. The GenServer holds no
  # persistent inventory state (state is always %{}). Every request could
  # execute directly in the calling process, but instead they are all queued
  # through a single mailbox, limiting throughput during order surges.

  @safety_stock_percentage 0.05

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Given a warehouse `snapshot` map and a `product_id`, returns
  `{:ok, availability_map}` or `{:error, :product_not_found}`.

  `snapshot` is a map of `%{product_id => %{on_hand: int, reserved: int, on_order: int}}`.
  """
  def check(pid, snapshot, product_id) do
    GenServer.call(pid, {:check, snapshot, product_id})
  end

  @doc """
  Returns `{:ok, true | false}` indicating whether `qty` units can be
  fulfilled for `product_id` from the given `snapshot`.
  """
  def can_fulfill?(pid, snapshot, product_id, qty) do
    GenServer.call(pid, {:can_fulfill?, snapshot, product_id, qty})
  end

  @doc "Returns `{:ok, reserved_count}` for a given product in the snapshot."
  def reserved_quantity(pid, snapshot, product_id) do
    GenServer.call(pid, {:reserved_quantity, snapshot, product_id})
  end

  @doc "Returns `{:ok, available_count}` — on-hand minus reserved and safety stock."
  def available_quantity(pid, snapshot, product_id) do
    GenServer.call(pid, {:available_quantity, snapshot, product_id})
  end

  @doc "Returns `{:ok, list}` of all products in the snapshot with low stock."
  def low_stock_products(pid, snapshot, threshold) do
    GenServer.call(pid, {:low_stock_products, snapshot, threshold})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:check, snapshot, product_id}, _from, state) do
    result =
      case Map.get(snapshot, product_id) do
        nil ->
          {:error, :product_not_found}

        %{on_hand: on_hand, reserved: reserved, on_order: on_order} ->
          safety  = trunc(on_hand * @safety_stock_percentage)
          avail   = max(on_hand - reserved - safety, 0)

          {:ok, %{
            product_id:       product_id,
            on_hand:          on_hand,
            reserved:         reserved,
            on_order:         on_order,
            safety_stock:     safety,
            available:        avail
          }}
      end

    {:reply, result, state}
  end

  def handle_call({:can_fulfill?, snapshot, product_id, qty}, _from, state) do
    result =
      case Map.get(snapshot, product_id) do
        nil ->
          {:error, :product_not_found}

        %{on_hand: on_hand, reserved: reserved} ->
          safety = trunc(on_hand * @safety_stock_percentage)
          avail  = max(on_hand - reserved - safety, 0)
          {:ok, avail >= qty}
      end

    {:reply, result, state}
  end

  def handle_call({:reserved_quantity, snapshot, product_id}, _from, state) do
    result =
      case Map.get(snapshot, product_id) do
        nil                     -> {:error, :product_not_found}
        %{reserved: reserved}   -> {:ok, reserved}
      end

    {:reply, result, state}
  end

  def handle_call({:available_quantity, snapshot, product_id}, _from, state) do
    result =
      case Map.get(snapshot, product_id) do
        nil ->
          {:error, :product_not_found}

        %{on_hand: on_hand, reserved: reserved} ->
          safety = trunc(on_hand * @safety_stock_percentage)
          {:ok, max(on_hand - reserved - safety, 0)}
      end

    {:reply, result, state}
  end

  def handle_call({:low_stock_products, snapshot, threshold}, _from, state) do
    low =
      snapshot
      |> Enum.filter(fn {_id, %{on_hand: oh, reserved: r}} ->
        safety = trunc(oh * @safety_stock_percentage)
        max(oh - r - safety, 0) < threshold
      end)
      |> Enum.map(fn {id, data} -> Map.put(data, :product_id, id) end)

    {:reply, {:ok, low}, state}
  end

  # VALIDATION: SMELL END
end
```
