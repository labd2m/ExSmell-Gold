# Annotated Bad Example 04

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@default_warehouse` defined at the top of `Inventory.StockManager`
- **Affected function(s):** `reserve_stock/3`, `release_stock/3`, `transfer_stock/4`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to populate `@default_warehouse`. Because module attributes are baked in at compile-time, and the Application Environment might not yet be available, this can result in a compilation warning or `ArgumentError`.

---

```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock reservations, releases, and inter-warehouse transfers.
  Stock levels are tracked per SKU and warehouse location. All mutations
  are logged for audit purposes.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is used in the module
  # VALIDATION: body to define a module attribute. Module attributes are frozen at
  # VALIDATION: compile-time; if the :inventory application has not been loaded by then,
  # VALIDATION: Elixir emits a warning or raises ArgumentError during compilation.
  @default_warehouse Application.fetch_env!(:inventory, :default_warehouse)
  # VALIDATION: SMELL END

  @low_stock_threshold 10
  @max_transfer_quantity 5_000

  @type sku :: String.t()
  @type warehouse_id :: String.t()
  @type quantity :: non_neg_integer()

  @type stock_operation_result ::
          {:ok, %{sku: sku(), warehouse_id: warehouse_id(), new_quantity: quantity()}}
          | {:error, :insufficient_stock | :warehouse_not_found | :invalid_quantity}

  @doc """
  Reserves `qty` units of `sku` in the specified warehouse (defaults to the
  configured default warehouse). Returns the updated available quantity.
  """
  @spec reserve_stock(sku(), quantity(), warehouse_id()) :: stock_operation_result()
  def reserve_stock(sku, qty, warehouse_id \\ @default_warehouse)
      when is_binary(sku) and is_integer(qty) and qty > 0 do
    Logger.info("Reserving stock sku=#{sku} qty=#{qty} warehouse=#{warehouse_id}")

    with {:ok, current} <- fetch_stock(sku, warehouse_id),
         :ok <- validate_sufficient_stock(current, qty),
         new_qty = current - qty,
         :ok <- persist_stock(sku, warehouse_id, new_qty) do
      maybe_warn_low_stock(sku, warehouse_id, new_qty)
      {:ok, %{sku: sku, warehouse_id: warehouse_id, new_quantity: new_qty}}
    end
  end

  @doc """
  Releases `qty` previously-reserved units of `sku` back to the warehouse.
  """
  @spec release_stock(sku(), quantity(), warehouse_id()) :: stock_operation_result()
  def release_stock(sku, qty, warehouse_id \\ @default_warehouse)
      when is_binary(sku) and is_integer(qty) and qty > 0 do
    Logger.info("Releasing stock sku=#{sku} qty=#{qty} warehouse=#{warehouse_id}")

    with {:ok, current} <- fetch_stock(sku, warehouse_id),
         new_qty = current + qty,
         :ok <- persist_stock(sku, warehouse_id, new_qty) do
      {:ok, %{sku: sku, warehouse_id: warehouse_id, new_quantity: new_qty}}
    end
  end

  @doc """
  Transfers `qty` units of `sku` from `source_warehouse` to `dest_warehouse`.
  Both the debit and credit are applied atomically (within the same transaction).
  """
  @spec transfer_stock(sku(), quantity(), warehouse_id(), warehouse_id()) ::
          {:ok, map()} | {:error, term()}
  def transfer_stock(sku, qty, source_warehouse, dest_warehouse)
      when is_binary(sku) and is_integer(qty) and qty > 0 and qty <= @max_transfer_quantity do
    Logger.info(
      "Transferring stock sku=#{sku} qty=#{qty} from=#{source_warehouse} to=#{dest_warehouse}"
    )

    with {:ok, _} <- reserve_stock(sku, qty, source_warehouse),
         {:ok, dest_result} <- release_stock(sku, qty, dest_warehouse) do
      Logger.info("Transfer complete sku=#{sku} qty=#{qty}")

      {:ok,
       %{
         sku: sku,
         transferred_qty: qty,
         source_warehouse: source_warehouse,
         dest_warehouse: dest_warehouse,
         dest_new_quantity: dest_result.new_quantity
       }}
    else
      {:error, reason} = err ->
        Logger.error("Transfer failed sku=#{sku} reason=#{inspect(reason)}")
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_stock(sku, warehouse_id) do
    case Inventory.Repo.get_stock(sku, warehouse_id) do
      {:ok, _level} = ok -> ok
      {:error, :not_found} -> {:error, :warehouse_not_found}
    end
  end

  defp validate_sufficient_stock(current, requested) when current >= requested, do: :ok
  defp validate_sufficient_stock(_, _), do: {:error, :insufficient_stock}

  defp persist_stock(sku, warehouse_id, new_qty) do
    Inventory.Repo.update_stock(sku, warehouse_id, new_qty)
  end

  defp maybe_warn_low_stock(sku, warehouse_id, qty) when qty < @low_stock_threshold do
    Logger.warning("Low stock alert sku=#{sku} warehouse=#{warehouse_id} remaining=#{qty}")
  end

  defp maybe_warn_low_stock(_, _, _), do: :ok
end
```
