# Example Bad 06 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Inventory.StockController.reserve_items/3`
- **Affected Function(s)**: `reserve_items/3`
- **Explanation**: The `strategy` parameter is defined with a default of `:fifo` to
  support alternative reservation strategies (e.g. `:lifo`, `:nearest_expiry`) in the
  future. In practice, every call site in this module — `process_order/2`,
  `reserve_for_transfer/2` — always calls `reserve_items/2`, never supplying a
  strategy value. The parameter is entirely speculative and adds no real capability.

## Code

```elixir
defmodule Inventory.StockController do
  @moduledoc """
  Manages stock reservations, adjustments, and transfers across warehouse
  locations. Ensures inventory integrity during order fulfilment and
  inter-warehouse movements.
  """

  alias Inventory.{StockItem, Reservation, Transfer, Location}
  alias Inventory.Repo

  @low_stock_threshold 10
  @reservation_ttl_hours 24

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `strategy \\ :fifo` was added to support
  # future reservation strategies such as :lifo or :nearest_expiry. Every call
  # site in this module—process_order/2 and reserve_for_transfer/2—always omits
  # the third argument, so :fifo is the only strategy ever used. The parameter
  # represents speculative flexibility that was never exercised.
  def reserve_items(order_id, line_items, strategy \\ :fifo) do
  # VALIDATION: SMELL END
    results =
      Enum.map(line_items, fn item ->
        available = fetch_available_stock(item.sku, item.warehouse_id, strategy)

        cond do
          available >= item.quantity ->
            create_reservation(order_id, item)

          true ->
            {:error, {:insufficient_stock, item.sku}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, r} -> r end)}
    else
      {:error, errors}
    end
  end

  def process_order(order_id, line_items) do
    case reserve_items(order_id, line_items) do
      {:ok, reservations} ->
        Enum.each(reservations, &confirm_reservation/1)
        {:ok, reservations}

      {:error, errors} ->
        {:error, errors}
    end
  end

  def reserve_for_transfer(transfer_id, items) do
    case reserve_items(transfer_id, items) do
      {:ok, reservations} ->
        Transfer
        |> Repo.get!(transfer_id)
        |> Transfer.changeset(%{status: :reserved})
        |> Repo.update()

        {:ok, reservations}

      {:error, errors} ->
        {:error, errors}
    end
  end

  def release_reservation(reservation_id) do
    reservation = Repo.get!(Reservation, reservation_id)

    reservation
    |> Reservation.changeset(%{status: :released, released_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def expire_stale_reservations do
    cutoff = DateTime.add(DateTime.utc_now(), -@reservation_ttl_hours * 3600, :second)

    Reservation
    |> Repo.all()
    |> Enum.filter(fn r ->
      r.status == :pending and DateTime.compare(r.created_at, cutoff) == :lt
    end)
    |> Enum.each(fn r ->
      r
      |> Reservation.changeset(%{status: :expired, released_at: DateTime.utc_now()})
      |> Repo.update()
    end)
  end

  def adjust_stock(sku, warehouse_id, delta, reason) do
    stock = Repo.get_by!(StockItem, sku: sku, warehouse_id: warehouse_id)

    new_qty = max(0, stock.quantity + delta)

    stock
    |> StockItem.changeset(%{
      quantity:    new_qty,
      last_reason: reason,
      updated_at:  DateTime.utc_now()
    })
    |> Repo.update()
  end

  def low_stock_alerts do
    StockItem
    |> Repo.all()
    |> Enum.filter(&(&1.quantity < @low_stock_threshold))
    |> Enum.map(&%{sku: &1.sku, warehouse_id: &1.warehouse_id, quantity: &1.quantity})
  end

  def stock_snapshot(warehouse_id) do
    StockItem
    |> Repo.all()
    |> Enum.filter(&(&1.warehouse_id == warehouse_id))
    |> Enum.map(&Map.take(&1, [:sku, :quantity, :reserved, :available]))
  end

  # --- Private ---

  defp fetch_available_stock(sku, warehouse_id, _strategy) do
    stock = Repo.get_by!(StockItem, sku: sku, warehouse_id: warehouse_id)
    stock.quantity - stock.reserved
  end

  defp create_reservation(order_id, item) do
    attrs = %{
      order_id:     order_id,
      sku:          item.sku,
      warehouse_id: item.warehouse_id,
      quantity:     item.quantity,
      status:       :pending,
      created_at:   DateTime.utc_now()
    }

    case Reservation.changeset(%Reservation{}, attrs) |> Repo.insert() do
      {:ok, reservation} -> {:ok, reservation}
      {:error, cs}       -> {:error, cs}
    end
  end

  defp confirm_reservation(reservation) do
    reservation
    |> Reservation.changeset(%{status: :confirmed, confirmed_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
```
