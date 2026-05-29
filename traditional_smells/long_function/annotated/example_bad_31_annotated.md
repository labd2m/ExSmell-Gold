# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Inventory.ReconciliationService.reconcile_warehouse/2`
- **Affected function(s):** `reconcile_warehouse/2`
- **Short explanation:** `reconcile_warehouse/2` handles snapshot loading, physical-count ingestion, discrepancy detection, threshold classification, write-off generation, reorder-flag setting, and audit-trail recording — seven separate concerns packed into one function with no helper delegation.

---

```elixir
defmodule Inventory.ReconciliationService do
  @moduledoc """
  Reconciles physical stock counts against system records,
  flags discrepancies, and triggers reorder workflows.
  """

  require Logger

  alias Inventory.{
    StockSnapshot, PhysicalCount, Discrepancy,
    WriteOff, ReorderAlert, AuditLog
  }

  @minor_threshold_pct  0.02
  @major_threshold_pct  0.10
  @critical_threshold   50
  @reorder_buffer_pct   0.15

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `reconcile_warehouse/2` combines
  # data loading, delta computation, multi-level classification, write-off
  # creation, reorder triggering, and audit persistence into a single
  # function that exceeds 100 lines and violates cohesion — each step
  # could be its own well-named private function.
  def reconcile_warehouse(warehouse_id, counted_at \\ DateTime.utc_now()) do
    Logger.info("Starting reconciliation for warehouse #{warehouse_id}")

    # 1. Load the most recent system snapshot
    snapshot = StockSnapshot.latest_for_warehouse(warehouse_id)

    unless snapshot do
      {:error, :no_snapshot_found}
    else
      # 2. Load the physical count records submitted for this warehouse
      physical_counts = PhysicalCount.list_for_warehouse(warehouse_id, counted_at)

      if physical_counts == [] do
        {:error, :no_physical_counts}
      else
        # 3. Index snapshot quantities by SKU
        snapshot_index =
          Map.new(snapshot.entries, fn entry -> {entry.sku, entry} end)

        # 4. Compute per-SKU deltas and classify discrepancies
        discrepancies =
          Enum.flat_map(physical_counts, fn count ->
            case Map.get(snapshot_index, count.sku) do
              nil ->
                Logger.warning("SKU #{count.sku} not found in snapshot — skipping")
                []

              snap_entry ->
                delta    = count.quantity - snap_entry.quantity
                delta_abs = abs(delta)

                if delta == 0 do
                  []
                else
                  pct_diff = if snap_entry.quantity > 0,
                    do:   delta_abs / snap_entry.quantity,
                    else: 1.0

                  severity =
                    cond do
                      delta_abs >= @critical_threshold               -> :critical
                      pct_diff  >= @major_threshold_pct              -> :major
                      pct_diff  >= @minor_threshold_pct              -> :minor
                      true                                           -> :negligible
                    end

                  [%{
                    sku:           count.sku,
                    expected:      snap_entry.quantity,
                    actual:        count.quantity,
                    delta:         delta,
                    delta_pct:     Float.round(pct_diff * 100, 2),
                    severity:      severity,
                    warehouse_id:  warehouse_id
                  }]
                end
            end
          end)

        Logger.info("Found #{length(discrepancies)} discrepancies in warehouse #{warehouse_id}")

        # 5. Persist discrepancy records
        inserted_discrepancies =
          Enum.map(discrepancies, fn d ->
            case Discrepancy.insert(%Discrepancy{
              sku:          d.sku,
              warehouse_id: d.warehouse_id,
              expected_qty: d.expected,
              actual_qty:   d.actual,
              delta:        d.delta,
              severity:     d.severity,
              reconciled_at: counted_at
            }) do
              {:ok, record}    -> record
              {:error, reason} ->
                Logger.error("Failed to insert discrepancy #{d.sku}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # 6. Generate write-offs for critical and major negative deltas
        write_offs =
          discrepancies
          |> Enum.filter(&(&1.delta < 0 and &1.severity in [:critical, :major]))
          |> Enum.map(fn d ->
            WriteOff.create(%{
              sku:          d.sku,
              warehouse_id: d.warehouse_id,
              quantity:     abs(d.delta),
              reason:       "inventory_reconciliation",
              approved_by:  "system",
              created_at:   counted_at
            })
          end)

        write_off_count = Enum.count(write_offs, &match?({:ok, _}, &1))
        Logger.info("#{write_off_count} write-offs created for warehouse #{warehouse_id}")

        # 7. Flag items below reorder threshold
        reorder_flags =
          physical_counts
          |> Enum.filter(fn count ->
            snap = Map.get(snapshot_index, count.sku)
            snap != nil and
              snap.reorder_point != nil and
              count.quantity <= snap.reorder_point * (1 + @reorder_buffer_pct)
          end)
          |> Enum.map(fn count ->
            ReorderAlert.upsert(%{
              sku:          count.sku,
              warehouse_id: warehouse_id,
              current_qty:  count.quantity,
              flagged_at:   counted_at
            })
          end)

        reorder_count = Enum.count(reorder_flags, &match?({:ok, _}, &1))

        # 8. Write audit log entry
        AuditLog.insert(%AuditLog{
          action:      "warehouse_reconciliation",
          entity:      "warehouse",
          entity_id:   warehouse_id,
          actor:       "system",
          metadata:    %{
            discrepancies: length(inserted_discrepancies),
            write_offs:    write_off_count,
            reorder_flags: reorder_count
          },
          inserted_at: counted_at
        })

        {:ok, %{
          warehouse_id:  warehouse_id,
          discrepancies: inserted_discrepancies,
          write_offs:    write_off_count,
          reorder_flags: reorder_count
        }}
      end
    end
  end
  # VALIDATION: SMELL END
end
```
