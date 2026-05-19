```elixir
defmodule InventoryStore do
  @moduledoc "Starts the shared inventory agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{stock: %{}, reservations: %{}, shipments: [], audit_log: []}
    end)
    pid
  end
end

defmodule InventoryReceiver do
  @moduledoc """
  Handles receiving new stock into the warehouse inventory agent.
  """

  def receive_stock(pid, sku, quantity) when quantity > 0 do
    Agent.update(pid, fn state ->
      updated_stock =
        Map.update(state.stock, sku, %{qty: quantity, reserved: 0}, fn existing ->
          %{existing | qty: existing.qty + quantity}
        end)

      log_entry = %{event: :received, sku: sku, qty: quantity, at: DateTime.utc_now()}

      %{state | stock: updated_stock, audit_log: [log_entry | state.audit_log]}
    end)

    :ok
  end

  def stock_level(pid, sku) do
    Agent.get(pid, fn state ->
      case Map.get(state.stock, sku) do
        nil -> 0
        entry -> entry.qty - entry.reserved
      end
    end)
  end
end

defmodule InventoryReserver do
  @moduledoc """
  Reserves stock for pending orders in the inventory agent.
  """

  def reserve(pid, order_id, sku, quantity) do
    available =
      Agent.get(pid, fn state ->
        case Map.get(state.stock, sku) do
          nil -> 0
          entry -> entry.qty - entry.reserved
        end
      end)

    if available >= quantity do
      Agent.update(pid, fn state ->
        updated_stock =
          Map.update!(state.stock, sku, fn entry ->
            %{entry | reserved: entry.reserved + quantity}
          end)

        updated_reservations = Map.put(state.reservations, order_id, %{sku: sku, qty: quantity})

        log_entry = %{event: :reserved, sku: sku, qty: quantity, order_id: order_id, at: DateTime.utc_now()}

        %{state | stock: updated_stock, reservations: updated_reservations,
          audit_log: [log_entry | state.audit_log]}
      end)

      {:ok, :reserved}
    else
      {:error, :insufficient_stock}
    end
  end
end

defmodule InventoryShipper do
  @moduledoc """
  Confirms shipment and reduces reserved stock in the inventory agent.
  """

  def ship(pid, order_id, carrier, tracking_number) do
    reservation = Agent.get(pid, fn state -> Map.get(state.reservations, order_id) end)

    case reservation do
      nil ->
        {:error, :reservation_not_found}

      %{sku: sku, qty: qty} ->
        Agent.update(pid, fn state ->
          updated_stock =
            Map.update!(state.stock, sku, fn entry ->
              %{entry | qty: entry.qty - qty, reserved: entry.reserved - qty}
            end)

          updated_reservations = Map.delete(state.reservations, order_id)

          shipment = %{
            order_id: order_id,
            sku: sku,
            qty: qty,
            carrier: carrier,
            tracking: tracking_number,
            shipped_at: DateTime.utc_now()
          }

          log_entry = %{event: :shipped, sku: sku, qty: qty, order_id: order_id, at: DateTime.utc_now()}

          %{state |
            stock: updated_stock,
            reservations: updated_reservations,
            shipments: [shipment | state.shipments],
            audit_log: [log_entry | state.audit_log]
          }
        end)

        {:ok, :shipped}
    end
  end
end

defmodule InventoryAuditor do
  @moduledoc """
  Produces discrepancy and audit reports from the inventory agent state.
  """

  def discrepancy_report(pid) do
    state = Agent.get(pid, fn s -> s end)

    discrepancies =
      Enum.flat_map(state.stock, fn {sku, entry} ->
        if entry.reserved > entry.qty do
          [%{sku: sku, reserved: entry.reserved, on_hand: entry.qty, delta: entry.reserved - entry.qty}]
        else
          []
        end
      end)

    %{
      discrepancies: discrepancies,
      total_skus: map_size(state.stock),
      pending_reservations: map_size(state.reservations),
      total_shipments: length(state.shipments),
      audit_entries: length(state.audit_log),
      generated_at: DateTime.utc_now()
    }
  end
end
```
