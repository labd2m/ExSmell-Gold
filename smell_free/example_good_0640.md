```elixir
defmodule Warehouse.ReservationSaga do
  @moduledoc """
  Coordinates multi-warehouse inventory reservation for a single order.
  When requested quantities cannot be fulfilled from one warehouse the saga
  attempts to split fulfilment across multiple sites. If no combination
  satisfies the full order the saga rolls back all partial reservations
  atomically, leaving inventory unchanged for concurrent orders.
  """

  alias Warehouse.{Inventory, Reservation, Repo}
  alias Ecto.Multi

  require Logger

  @type item :: %{sku_id: binary(), quantity: pos_integer()}
  @type warehouse_id :: binary()
  @type reservation_plan :: [%{warehouse_id: warehouse_id(), sku_id: binary(), quantity: pos_integer()}]

  @doc """
  Attempts to reserve all items in `order_items` from available warehouses.
  Returns `{:ok, reservations}` with the multi-warehouse plan, or
  `{:error, :insufficient_stock}` when the full order cannot be satisfied.
  """
  @spec reserve(binary(), [item()]) ::
          {:ok, [Reservation.t()]} | {:error, :insufficient_stock | term()}
  def reserve(order_id, order_items)
      when is_binary(order_id) and is_list(order_items) do
    with {:ok, plan} <- build_reservation_plan(order_items),
         {:ok, reservations} <- commit_plan(order_id, plan) do
      Logger.info("Inventory reserved",
        order_id: order_id,
        warehouse_count: plan |> Enum.map(& &1.warehouse_id) |> Enum.uniq() |> length()
      )

      {:ok, reservations}
    end
  end

  @doc """
  Releases all reservations associated with `order_id`. Idempotent; safe
  to call even when some reservations have already been released.
  """
  @spec release(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def release(order_id) when is_binary(order_id) do
    {count, _} =
      Repo.delete_all(from(r in Reservation, where: r.order_id == ^order_id))

    Inventory.return_reserved(order_id)
    Logger.info("Reservations released", order_id: order_id, count: count)
    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_reservation_plan(order_items) do
    warehouses = Inventory.list_warehouses_by_capacity()

    {plan, unfulfilled} =
      Enum.reduce(order_items, {[], []}, fn item, {plan_acc, unf_acc} ->
        case allocate_item(item, warehouses, plan_acc) do
          {:ok, allocations} -> {plan_acc ++ allocations, unf_acc}
          :insufficient -> {plan_acc, [item | unf_acc]}
        end
      end)

    if unfulfilled == [] do
      {:ok, plan}
    else
      skus = Enum.map(unfulfilled, & &1.sku_id)
      Logger.info("Insufficient stock for items", skus: skus)
      {:error, :insufficient_stock}
    end
  end

  defp allocate_item(%{sku_id: sku_id, quantity: needed}, warehouses, existing_plan) do
    already_allocated =
      existing_plan
      |> Enum.filter(&(&1.sku_id == sku_id))
      |> Enum.sum_by(& &1.quantity)

    remaining = needed - already_allocated

    if remaining <= 0 do
      {:ok, []}
    else
      pick_from_warehouses(sku_id, remaining, warehouses, [])
    end
  end

  defp pick_from_warehouses(_sku_id, 0, _warehouses, acc), do: {:ok, acc}
  defp pick_from_warehouses(_sku_id, _needed, [], _acc), do: :insufficient

  defp pick_from_warehouses(sku_id, needed, [warehouse | rest], acc) do
    available = Inventory.available_quantity(warehouse.id, sku_id)

    if available > 0 do
      take = min(available, needed)
      allocation = %{warehouse_id: warehouse.id, sku_id: sku_id, quantity: take}
      pick_from_warehouses(sku_id, needed - take, rest, [allocation | acc])
    else
      pick_from_warehouses(sku_id, needed, rest, acc)
    end
  end

  defp commit_plan(order_id, plan) do
    multi =
      plan
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {allocation, idx}, multi ->
        step = {:reserve, idx}

        Multi.run(multi, step, fn repo, _ ->
          with :ok <- Inventory.decrement_stock(allocation.warehouse_id, allocation.sku_id, allocation.quantity),
               {:ok, res} <- repo.insert(Reservation.changeset(%Reservation{}, Map.put(allocation, :order_id, order_id))) do
            {:ok, res}
          end
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, results} ->
        reservations = results |> Map.values() |> Enum.filter(&is_struct(&1, Reservation))
        {:ok, reservations}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end
end
```
