# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `InventoryAgent` module — `Agent` performing complex business operations
- **Affected function(s):** `reserve_stock/3`, `fulfil_order/2`, `reorder_if_needed/2`
- **Short explanation:** The `Agent` here does far more than share global state. It runs reservation logic, triggers reorder workflows, and calls external services — responsibilities that belong in a `GenServer`.

```elixir
defmodule MyApp.InventoryAgent do
  @moduledoc """
  Tracks warehouse stock levels and manages reservation/fulfilment lifecycle.
  """

  use Agent

  alias MyApp.{PurchasingService, WarehouseRepo}
  alias MyApp.Inventory.{Reservation, StockEntry}

  @reorder_threshold 20

  def start_link(_opts) do
    initial =
      WarehouseRepo.all_stock()
      |> Enum.into(%{}, fn entry -> {entry.sku, entry} end)

    Agent.start_link(fn -> %{stock: initial, reservations: %{}, reorder_pending: MapSet.new()} end,
      name: __MODULE__
    )
  end

  def stock_level(sku) do
    Agent.get(__MODULE__, fn %{stock: stock} ->
      case Map.fetch(stock, sku) do
        {:ok, entry} -> {:ok, entry.quantity}
        :error -> {:error, :not_found}
      end
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent executes complex, multi-step
  # inventory management logic — including conditional reorder triggers and external
  # service calls — rather than simply sharing state. A GenServer is the correct
  # abstraction for processes that orchestrate business workflows.

  def reserve_stock(sku, qty, order_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      entry = Map.get(state.stock, sku)

      cond do
        is_nil(entry) ->
          {{:error, :unknown_sku}, state}

        entry.quantity < qty ->
          {{:error, :insufficient_stock}, state}

        true ->
          reservation = %Reservation{
            id: Ecto.UUID.generate(),
            sku: sku,
            qty: qty,
            order_id: order_id,
            reserved_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
          }

          updated_entry = %{entry | quantity: entry.quantity - qty, reserved: entry.reserved + qty}

          new_stock = Map.put(state.stock, sku, updated_entry)
          new_reservations = Map.put(state.reservations, reservation.id, reservation)

          new_state = %{state | stock: new_stock, reservations: new_reservations}

          {{:ok, reservation}, new_state}
      end
    end)
  end

  def fulfil_order(reservation_id, warehouse_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.reservations, reservation_id) do
        :error ->
          {{:error, :unknown_reservation}, state}

        {:ok, reservation} ->
          case WarehouseRepo.fulfil(reservation, warehouse_id) do
            {:ok, fulfilment} ->
              entry = Map.get(state.stock, reservation.sku)
              updated_entry = %{entry | reserved: entry.reserved - reservation.qty}
              new_stock = Map.put(state.stock, reservation.sku, updated_entry)
              new_reservations = Map.delete(state.reservations, reservation_id)

              new_state = %{state | stock: new_stock, reservations: new_reservations}

              {{:ok, fulfilment}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def reorder_if_needed(sku, supplier_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      entry = Map.get(state.stock, sku)

      cond do
        is_nil(entry) ->
          {{:error, :unknown_sku}, state}

        MapSet.member?(state.reorder_pending, sku) ->
          {{:ok, :already_pending}, state}

        entry.quantity <= @reorder_threshold ->
          reorder_qty = entry.reorder_qty || 100

          case PurchasingService.create_purchase_order(sku, reorder_qty, supplier_id) do
            {:ok, po} ->
              new_pending = MapSet.put(state.reorder_pending, sku)
              {{:ok, po}, %{state | reorder_pending: new_pending}}

            {:error, reason} ->
              {{:error, reason}, state}
          end

        true ->
          {{:ok, :sufficient_stock}, state}
      end
    end)
  end

  # VALIDATION: SMELL END

  def list_reservations do
    Agent.get(__MODULE__, fn state -> Map.values(state.reservations) end)
  end

  def expire_stale_reservations do
    now = DateTime.utc_now()

    Agent.update(__MODULE__, fn state ->
      {expired, active} =
        Enum.split_with(state.reservations, fn {_id, res} ->
          DateTime.compare(res.expires_at, now) == :lt
        end)

      restored_stock =
        Enum.reduce(expired, state.stock, fn {_id, res}, stock ->
          Map.update!(stock, res.sku, fn entry ->
            %{entry | quantity: entry.quantity + res.qty, reserved: entry.reserved - res.qty}
          end)
        end)

      %{state | reservations: Map.new(active), stock: restored_stock}
    end)
  end
end
```
