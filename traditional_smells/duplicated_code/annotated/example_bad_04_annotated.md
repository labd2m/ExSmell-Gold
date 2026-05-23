# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Inventory.StockManager.reserve_items/2` and `Inventory.StockManager.fulfill_order/2` |
| **Affected functions** | `reserve_items/2`, `fulfill_order/2` |
| **Short explanation** | Both functions independently duplicate the logic to check whether each requested item has sufficient stock (comparing `requested_qty` against `available_qty`). If the availability check rule changes (e.g., including a safety buffer), it must be updated in two separate places. |

```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock reservation and order fulfillment.
  Ensures items are available before committing inventory changes.
  """

  alias Inventory.Repo
  alias Inventory.StockItem
  alias Inventory.Reservation
  alias Inventory.Order

  @doc """
  Attempts to reserve stock for a list of line items.
  Each element in `line_items` is a map with `:sku` and `:qty`.
  """
  def reserve_items(order_id, line_items) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the logic for checking whether
    # each item has enough available stock (Repo.get_by + comparing
    # available_qty against requested qty) is duplicated in fulfill_order/2.
    unavailable =
      Enum.reject(line_items, fn %{sku: sku, qty: requested_qty} ->
        case Repo.get_by(StockItem, sku: sku) do
          nil -> false
          item -> item.available_qty >= requested_qty
        end
      end)
    # VALIDATION: SMELL END

    if unavailable != [] do
      skus = Enum.map(unavailable, & &1.sku)
      {:error, {:insufficient_stock, skus}}
    else
      reservations =
        Enum.map(line_items, fn %{sku: sku, qty: qty} ->
          item = Repo.get_by!(StockItem, sku: sku)
          Repo.update!(%{item | available_qty: item.available_qty - qty, reserved_qty: item.reserved_qty + qty})
          %Reservation{order_id: order_id, sku: sku, qty: qty, status: :pending}
        end)

      Repo.insert_all(Reservation, reservations)
      {:ok, order_id}
    end
  end

  @doc """
  Fulfills a confirmed order by permanently deducting stock.
  Verifies stock availability again at fulfillment time.
  """
  def fulfill_order(%Order{} = order) do
    line_items = Repo.all_by(Reservation, order_id: order.id, status: :pending)

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this availability check is a copy of
    # the stock validation block in reserve_items/2.
    unavailable =
      Enum.reject(line_items, fn %{sku: sku, qty: requested_qty} ->
        case Repo.get_by(StockItem, sku: sku) do
          nil -> false
          item -> item.available_qty >= requested_qty
        end
      end)
    # VALIDATION: SMELL END

    if unavailable != [] do
      skus = Enum.map(unavailable, & &1.sku)
      {:error, {:stock_gap_on_fulfillment, skus}}
    else
      Enum.each(line_items, fn %{sku: sku, qty: qty} ->
        item = Repo.get_by!(StockItem, sku: sku)

        Repo.update!(%{
          item
          | on_hand_qty: item.on_hand_qty - qty,
            reserved_qty: item.reserved_qty - qty
        })

        Repo.update_where(Reservation, [order_id: order.id, sku: sku], status: :fulfilled)
      end)

      {:ok, :fulfilled}
    end
  end

  @doc """
  Returns current stock levels for a list of SKUs.
  """
  def stock_levels(skus) when is_list(skus) do
    skus
    |> Enum.map(fn sku ->
      case Repo.get_by(StockItem, sku: sku) do
        nil -> {sku, :not_found}
        item -> {sku, %{available: item.available_qty, reserved: item.reserved_qty, on_hand: item.on_hand_qty}}
      end
    end)
    |> Map.new()
  end
end
```
