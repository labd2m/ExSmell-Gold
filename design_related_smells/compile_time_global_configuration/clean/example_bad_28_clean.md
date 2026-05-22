```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock levels and reservations across warehouse locations.
  A default warehouse identifier is sourced from application configuration
  and used when callers do not supply an explicit warehouse.
  """

  require Logger

  @default_warehouse_id Application.fetch_env!(:inventory, :default_warehouse_id)

  @max_reservation_minutes 30
  @low_stock_threshold 10

  @type sku :: String.t()
  @type warehouse_id :: String.t()
  @type reservation_id :: String.t()

  @type reservation :: %{
          reservation_id: reservation_id(),
          sku: sku(),
          quantity: pos_integer(),
          warehouse_id: warehouse_id(),
          reserved_until: DateTime.t()
        }

  @spec reserve_stock(sku(), pos_integer(), warehouse_id()) ::
          {:ok, reservation()} | {:error, :insufficient_stock | :sku_not_found | :db_error}
  def reserve_stock(sku, quantity, warehouse_id \\ @default_warehouse_id)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    Logger.debug("Reserving stock", sku: sku, quantity: quantity, warehouse: warehouse_id)

    with {:ok, available} <- fetch_available(sku, warehouse_id),
         :ok <- assert_sufficient(available, quantity),
         {:ok, reservation} <- create_reservation(sku, quantity, warehouse_id) do
      maybe_warn_low_stock(sku, warehouse_id, available - quantity)
      {:ok, reservation}
    end
  end

  @spec release_reservation(reservation_id(), warehouse_id()) ::
          :ok | {:error, :not_found | :already_released | :db_error}
  def release_reservation(reservation_id, warehouse_id \\ @default_warehouse_id)
      when is_binary(reservation_id) do
    Logger.debug("Releasing reservation",
      reservation_id: reservation_id,
      warehouse: warehouse_id
    )

    case lookup_reservation(reservation_id, warehouse_id) do
      {:ok, %{status: :released}} ->
        {:error, :already_released}

      {:ok, reservation} ->
        do_release(reservation)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec adjust_quantity(sku(), integer(), warehouse_id()) ::
          {:ok, integer()} | {:error, :sku_not_found | :negative_stock | :db_error}
  def adjust_quantity(sku, delta, warehouse_id \\ @default_warehouse_id)
      when is_binary(sku) and is_integer(delta) do
    with {:ok, current} <- fetch_available(sku, warehouse_id),
         new_quantity = current + delta,
         :ok <- assert_non_negative(new_quantity),
         {:ok, _} <- persist_quantity(sku, warehouse_id, new_quantity) do
      Logger.info("Stock adjusted",
        sku: sku,
        delta: delta,
        new_quantity: new_quantity,
        warehouse: warehouse_id
      )

      {:ok, new_quantity}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_available(sku, warehouse_id) do
    case stock_repo().get_available(sku, warehouse_id) do
      nil -> {:error, :sku_not_found}
      qty -> {:ok, qty}
    end
  end

  defp assert_sufficient(available, required) when available >= required, do: :ok
  defp assert_sufficient(_, _), do: {:error, :insufficient_stock}

  defp assert_non_negative(qty) when qty >= 0, do: :ok
  defp assert_non_negative(_), do: {:error, :negative_stock}

  defp create_reservation(sku, quantity, warehouse_id) do
    reserved_until = DateTime.add(DateTime.utc_now(), @max_reservation_minutes * 60, :second)

    reservation = %{
      reservation_id: generate_id(),
      sku: sku,
      quantity: quantity,
      warehouse_id: warehouse_id,
      reserved_until: reserved_until
    }

    case stock_repo().insert_reservation(reservation) do
      :ok -> {:ok, reservation}
      {:error, _} -> {:error, :db_error}
    end
  end

  defp do_release(reservation) do
    case stock_repo().update_reservation(reservation.reservation_id, %{status: :released}) do
      :ok -> :ok
      {:error, _} -> {:error, :db_error}
    end
  end

  defp persist_quantity(sku, warehouse_id, quantity) do
    case stock_repo().update_quantity(sku, warehouse_id, quantity) do
      :ok -> {:ok, quantity}
      {:error, _} -> {:error, :db_error}
    end
  end

  defp lookup_reservation(id, warehouse_id) do
    case stock_repo().get_reservation(id, warehouse_id) do
      nil -> {:error, :not_found}
      res -> {:ok, res}
    end
  end

  defp maybe_warn_low_stock(sku, warehouse_id, remaining) do
    if remaining <= @low_stock_threshold do
      Logger.warning("Low stock alert", sku: sku, warehouse: warehouse_id, remaining: remaining)
    end
  end

  defp stock_repo, do: Application.get_env(:inventory, :stock_repo, Inventory.Repo)
  defp generate_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
```
