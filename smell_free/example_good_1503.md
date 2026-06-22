```elixir
defmodule Warehouse.Inventory.StockAgent do
  @moduledoc """
  Manages in-memory stock level state for a single warehouse location.

  All mutations are routed through this module's public API to ensure
  consistent validation and atomicity of state transitions.
  """

  use Agent

  alias Warehouse.Inventory.StockLevel

  @type location_id :: String.t()
  @type sku :: String.t()
  @type quantity :: non_neg_integer()
  @type stock_map :: %{sku() => quantity()}

  @spec start_link(location_id()) :: Agent.on_start()
  def start_link(location_id) when is_binary(location_id) do
    Agent.start_link(fn -> %{} end, name: via(location_id))
  end

  @doc """
  Returns the current quantity for a given SKU at this location.
  Returns `0` if the SKU has never been stocked.
  """
  @spec get_quantity(location_id(), sku()) :: quantity()
  def get_quantity(location_id, sku) when is_binary(location_id) and is_binary(sku) do
    Agent.get(via(location_id), fn stock -> Map.get(stock, sku, 0) end)
  end

  @doc """
  Returns a snapshot of all SKUs and their quantities at the location.
  """
  @spec list_stock(location_id()) :: stock_map()
  def list_stock(location_id) when is_binary(location_id) do
    Agent.get(via(location_id), fn stock -> stock end)
  end

  @doc """
  Adds units to an existing SKU or initializes it if not present.
  """
  @spec receive_stock(location_id(), sku(), quantity()) ::
          {:ok, quantity()} | {:error, :invalid_quantity}
  def receive_stock(location_id, sku, qty)
      when is_binary(location_id) and is_binary(sku) and is_integer(qty) and qty > 0 do
    Agent.update(via(location_id), fn stock ->
      Map.update(stock, sku, qty, &(&1 + qty))
    end)

    {:ok, get_quantity(location_id, sku)}
  end

  def receive_stock(_location_id, _sku, _qty), do: {:error, :invalid_quantity}

  @doc """
  Deducts units from a SKU's stock. Returns an error if stock is insufficient.
  """
  @spec deduct_stock(location_id(), sku(), quantity()) ::
          {:ok, quantity()} | {:error, :insufficient_stock | :invalid_quantity}
  def deduct_stock(location_id, sku, qty)
      when is_binary(location_id) and is_binary(sku) and is_integer(qty) and qty > 0 do
    current = get_quantity(location_id, sku)

    if current >= qty do
      Agent.update(via(location_id), fn stock ->
        Map.update!(stock, sku, &(&1 - qty))
      end)

      {:ok, get_quantity(location_id, sku)}
    else
      {:error, :insufficient_stock}
    end
  end

  def deduct_stock(_location_id, _sku, _qty), do: {:error, :invalid_quantity}

  @doc """
  Removes a SKU entry entirely from this location's stock map.
  """
  @spec remove_sku(location_id(), sku()) :: :ok
  def remove_sku(location_id, sku) when is_binary(location_id) and is_binary(sku) do
    Agent.update(via(location_id), fn stock -> Map.delete(stock, sku) end)
  end

  @doc """
  Checks whether the agent for a given location is currently running.
  """
  @spec alive?(location_id()) :: boolean()
  def alive?(location_id) when is_binary(location_id) do
    case Registry.lookup(Warehouse.Registry, location_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  defp via(location_id) do
    {:via, Registry, {Warehouse.Registry, location_id}}
  end
end
```
