# Annotated Bad Example 42

- **Smell name:** GenServer Envy
- **Expected smell location:** `InventoryStore` module — `Agent`-based process
- **Affected functions:** `compute_reorder_list/0`, `apply_stock_adjustment/3`, `archive_obsolete_skus/1`
- **Short explanation:** The `Agent` is correctly used to hold shared inventory state, but it also runs isolated computations and side-effectful routines (reorder analysis, adjustment logging, SKU archival) that have no relevance to other processes. These tasks do not need shared-state access and should live in a plain module or a `GenServer`.

```elixir
defmodule InventoryStore do
  @moduledoc """
  Central in-memory store for warehouse inventory levels.
  Tracks stock quantities, reorder thresholds, and product metadata
  across the warehouse management system.
  """

  use Agent

  require Logger

  @type sku_entry :: %{
          sku: String.t(),
          name: String.t(),
          quantity: non_neg_integer(),
          reorder_threshold: non_neg_integer(),
          reorder_quantity: non_neg_integer(),
          unit_cost: float(),
          location: String.t(),
          active: boolean()
        }

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Registers a new SKU in the inventory store."
  def register_sku(entry) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, entry.sku, entry)
    end)
  end

  @doc "Returns the current stock level for a given SKU."
  def get_quantity(sku) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state, sku) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.quantity}
      end
    end)
  end

  @doc "Increases stock for a SKU after a goods receipt."
  def receive_stock(sku, quantity) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, sku, fn entry ->
        %{entry | quantity: entry.quantity + quantity}
      end)
    end)
  end

  @doc "Decreases stock for a SKU after a fulfillment pick."
  def deduct_stock(sku, quantity) do
    Agent.get_and_update(__MODULE__, fn state ->
      entry = Map.fetch!(state, sku)

      if entry.quantity >= quantity do
        updated = %{entry | quantity: entry.quantity - quantity}
        {:ok, Map.put(state, sku, updated)}
      else
        {{:error, :insufficient_stock}, state}
      end
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because compute_reorder_list/0,
  # apply_stock_adjustment/3, and archive_obsolete_skus/1 perform isolated
  # computation and write side-effects (logging, filtering, producing reports)
  # that are of no interest to other processes sharing this Agent's state.
  # These operations execute entirely inside Agent.get/2 callbacks and belong
  # in a plain module or GenServer, not in an Agent.

  @doc "Computes a reorder report for SKUs below threshold — isolated task."
  def compute_reorder_list do
    Agent.get(__MODULE__, fn state ->
      state
      |> Map.values()
      |> Enum.filter(fn e -> e.active and e.quantity <= e.reorder_threshold end)
      |> Enum.map(fn e ->
        deficit = max(e.reorder_quantity - e.quantity, 0)
        estimated_cost = Float.round(deficit * e.unit_cost, 2)

        %{
          sku: e.sku,
          name: e.name,
          current_qty: e.quantity,
          reorder_qty: deficit,
          estimated_cost: estimated_cost,
          location: e.location
        }
      end)
      |> Enum.sort_by(& &1.estimated_cost, :desc)
    end)
  end

  @doc "Applies a manual stock adjustment with a reason code — isolated task."
  def apply_stock_adjustment(sku, delta, reason) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, sku) do
        nil ->
          {{:error, :not_found}, state}

        entry ->
          new_qty = max(entry.quantity + delta, 0)

          log_entry = %{
            sku: sku,
            previous_qty: entry.quantity,
            adjustment: delta,
            new_qty: new_qty,
            reason: reason,
            adjusted_at: DateTime.utc_now()
          }

          Logger.info("[InventoryStore] Adjustment: #{inspect(log_entry)}")

          updated_entry = %{entry | quantity: new_qty}
          {{:ok, log_entry}, Map.put(state, sku, updated_entry)}
      end
    end)
  end

  @doc "Archives a list of SKUs marked as discontinued — isolated task."
  def archive_obsolete_skus(sku_list) do
    Agent.get_and_update(__MODULE__, fn state ->
      {archived, new_state} =
        Enum.reduce(sku_list, {[], state}, fn sku, {acc, s} ->
          case Map.get(s, sku) do
            nil ->
              {acc, s}

            entry ->
              updated = %{entry | active: false}
              {[sku | acc], Map.put(s, sku, updated)}
          end
        end)

      report = %{
        archived_count: length(archived),
        archived_skus: Enum.reverse(archived),
        archived_at: DateTime.utc_now()
      }

      Logger.info("[InventoryStore] Archived SKUs: #{inspect(report)}")
      {report, new_state}
    end)
  end

  # VALIDATION: SMELL END

  @doc "Returns all active SKU entries."
  def list_active_skus do
    Agent.get(__MODULE__, fn state ->
      state |> Map.values() |> Enum.filter(& &1.active)
    end)
  end
end
```
