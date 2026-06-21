# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `InventoryStore.reserve_stock/3`
- **Affected function(s):** `InventoryStore.reserve_stock/3`, `OrderFulfillment.allocate_items/2`
- **Short explanation:** `InventoryStore.reserve_stock/3` raises a `RuntimeError` when stock is insufficient or a product is not found — both are entirely normal, expected states in an e-commerce inventory system. The calling module `OrderFulfillment.allocate_items/2` is compelled to use `try/rescue` for routine branching logic. Without a `{:ok, reservation} | {:error, reason}` return shape, callers cannot use idiomatic `case` or `with` constructs for error handling.

---

## Code

```elixir
defmodule InventoryStore do
  @moduledoc """
  Manages product stock levels and reservations for the warehouse subsystem.
  Provides stock querying, reservation, and release operations.
  """

  use Agent

  defstruct [:stock, :reservations]

  def start_link(initial_stock) do
    Agent.start_link(
      fn ->
        %__MODULE__{
          stock: initial_stock,
          reservations: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def current_stock(product_id) do
    state = Agent.get(__MODULE__, & &1)

    case Map.fetch(state.stock, product_id) do
      {:ok, qty} -> qty
      :error -> 0
    end
  end

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because reserve_stock/3 raises RuntimeError for
  # VALIDATION: expected, non-exceptional business conditions: unknown product IDs
  # VALIDATION: and insufficient stock levels are entirely routine in an inventory
  # VALIDATION: system. Callers like OrderFulfillment.allocate_items/2 must use
  # VALIDATION: try/rescue to manage ordinary flow, instead of pattern-matching
  # VALIDATION: on {:ok, _} | {:error, _} tuples.
  def reserve_stock(product_id, quantity, reservation_ref) do
    state = Agent.get(__MODULE__, & &1)

    unless Map.has_key?(state.stock, product_id) do
      raise RuntimeError,
        message: "Product #{product_id} not found in inventory"
    end

    available = Map.fetch!(state.stock, product_id)

    if available < quantity do
      raise RuntimeError,
        message:
          "Insufficient stock for product #{product_id}: " <>
            "requested #{quantity}, available #{available}"
    end

    Agent.update(__MODULE__, fn s ->
      updated_stock = Map.update!(s.stock, product_id, &(&1 - quantity))

      updated_reservations =
        Map.update(s.reservations, reservation_ref, [{product_id, quantity}], fn existing ->
          [{product_id, quantity} | existing]
        end)

      %{s | stock: updated_stock, reservations: updated_reservations}
    end)

    %{
      reservation_ref: reservation_ref,
      product_id: product_id,
      quantity: quantity,
      reserved_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  def release_reservation(reservation_ref) do
    state = Agent.get(__MODULE__, & &1)

    case Map.fetch(state.reservations, reservation_ref) do
      {:ok, items} ->
        Agent.update(__MODULE__, fn s ->
          restored_stock =
            Enum.reduce(items, s.stock, fn {pid, qty}, acc ->
              Map.update(acc, pid, qty, &(&1 + qty))
            end)

          %{s | stock: restored_stock, reservations: Map.delete(s.reservations, reservation_ref)}
        end)

        :ok

      :error ->
        {:error, :not_found}
    end
  end
end

defmodule OrderFulfillment do
  @moduledoc """
  Coordinates item allocation across the inventory for incoming orders.
  """

  require Logger

  alias InventoryStore

  def allocate_items(order_id, line_items) do
    reservation_ref = "order-#{order_id}-#{System.system_time(:millisecond)}"

    results =
      Enum.reduce_while(line_items, {:ok, []}, fn item, {:ok, acc} ->
        # Forced to use try/rescue because InventoryStore.reserve_stock/3
        # only signals errors via raised exceptions, not return values.
        try do
          reservation =
            InventoryStore.reserve_stock(item.product_id, item.quantity, reservation_ref)

          {:cont, {:ok, [reservation | acc]}}
        rescue
          e in RuntimeError ->
            Logger.warning(
              "Allocation failed for order #{order_id}, " <>
                "product #{item.product_id}: #{e.message}"
            )

            {:halt, {:error, e.message}}
        end
      end)

    case results do
      {:ok, reservations} ->
        Logger.info(
          "All #{length(reservations)} items allocated for order #{order_id} " <>
            "under ref #{reservation_ref}"
        )

        {:ok, %{order_id: order_id, reservation_ref: reservation_ref, reservations: reservations}}

      {:error, reason} ->
        InventoryStore.release_reservation(reservation_ref)
        Logger.info("Released partial reservation #{reservation_ref} due to failure")
        {:error, reason}
    end
  end

  def confirm_fulfillment(order_id, reservation_ref) do
    Logger.info("Fulfillment confirmed for order #{order_id}, ref #{reservation_ref}")
    :ok
  end
end
```
