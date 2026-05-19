# Annotated Example 05 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Inventory.ReservationAgent.open/1`
- **Affected function(s):** `open/1`
- **Short explanation:** One Agent process is started per warehouse SKU via `Agent.start/2` outside any supervision tree. In a warehouse with thousands of SKUs, these unsupervised agents accumulate. A crash in one agent silently loses all reservation data for that SKU with no automatic recovery.

```elixir
defmodule Inventory.ReservationAgent do
  @moduledoc """
  Manages stock reservations for a single SKU in a warehouse.
  Prevents over-selling by tracking confirmed and pending reservations
  against available stock.
  """

  @reservation_ttl_seconds 900

  defstruct [
    :sku,
    :available_qty,
    :reservations
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `Agent.start/2` (not `Agent.start_link/2`)
  # creates a long-running inventory-reservation process with no supervisor.
  # One of these is opened per SKU on first access. A production system can have
  # tens of thousands of SKUs active simultaneously. If an agent crashes (e.g., due
  # to a bad reservation struct), inventory reservations for that SKU are permanently
  # lost — no supervisor will restart it, and the available stock count becomes
  # inconsistent.
  def open(sku) do
    initial = %__MODULE__{
      sku: sku,
      available_qty: fetch_stock_from_db(sku),
      reservations: %{}
    }

    Agent.start(fn -> initial end, name: via_name(sku))
  end
  # VALIDATION: SMELL END

  @doc """
  Attempts to reserve `qty` units for `order_id`.
  Returns {:ok, reservation_id} or {:error, :insufficient_stock}.
  """
  def reserve(sku, order_id, qty) when is_integer(qty) and qty > 0 do
    Agent.get_and_update(via_name(sku), fn state ->
      if state.available_qty >= qty do
        reservation_id = generate_reservation_id()
        expires_at = DateTime.add(DateTime.utc_now(), @reservation_ttl_seconds, :second)

        reservation = %{
          order_id: order_id,
          qty: qty,
          reserved_at: DateTime.utc_now(),
          expires_at: expires_at,
          status: :pending
        }

        new_state = %{
          state
          | available_qty: state.available_qty - qty,
            reservations: Map.put(state.reservations, reservation_id, reservation)
        }

        {{:ok, reservation_id}, new_state}
      else
        {{:error, :insufficient_stock}, state}
      end
    end)
  end

  @doc "Confirms a reservation, marking the stock as sold."
  def confirm(sku, reservation_id) do
    Agent.update(via_name(sku), fn state ->
      case Map.fetch(state.reservations, reservation_id) do
        {:ok, res} ->
          updated = Map.put(state.reservations, reservation_id, %{res | status: :confirmed})
          %{state | reservations: updated}

        :error ->
          state
      end
    end)
  end

  @doc "Releases a reservation, returning stock to available pool."
  def release(sku, reservation_id) do
    Agent.update(via_name(sku), fn state ->
      case Map.pop(state.reservations, reservation_id) do
        {nil, _} ->
          state

        {res, remaining} ->
          qty_to_restore = if res.status == :pending, do: res.qty, else: 0
          %{state | available_qty: state.available_qty + qty_to_restore, reservations: remaining}
      end
    end)
  end

  @doc "Returns the current snapshot of available stock and active reservations."
  def snapshot(sku) do
    Agent.get(via_name(sku), fn state ->
      now = DateTime.utc_now()
      active = Enum.count(state.reservations, fn {_, r} -> DateTime.compare(now, r.expires_at) == :lt end)

      %{
        sku: state.sku,
        available_qty: state.available_qty,
        active_reservations: active,
        total_reservations: map_size(state.reservations)
      }
    end)
  end

  @doc "Expires stale pending reservations and restores their stock."
  def expire_stale(sku) do
    Agent.update(via_name(sku), fn state ->
      now = DateTime.utc_now()

      {stale, fresh} =
        Enum.split_with(state.reservations, fn {_id, r} ->
          r.status == :pending and DateTime.compare(now, r.expires_at) != :lt
        end)

      qty_restored = Enum.sum(Enum.map(stale, fn {_id, r} -> r.qty end))

      %{
        state
        | available_qty: state.available_qty + qty_restored,
          reservations: Map.new(fresh)
      }
    end)
  end

  defp via_name(sku) do
    {:via, Registry, {Inventory.ReservationRegistry, sku}}
  end

  defp generate_reservation_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower)
  end

  defp fetch_stock_from_db(_sku) do
    # Simulated DB lookup
    100
  end
end
```
