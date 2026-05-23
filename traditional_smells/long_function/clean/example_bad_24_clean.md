```elixir
defmodule Inventory.CycleCountReconciler do
  @moduledoc """
  Reconciles a completed physical cycle count against system stock levels,
  records adjustments, flags large discrepancies for investigation, and
  closes the count session.
  """

  alias Inventory.{CycleCount, CycleCountLine, StockItem, StockAdjustment, InvestigationTask, Repo}
  alias Notifications.Dispatcher
  require Logger

  @variance_warn_pct  0.05
  @variance_flag_pct  0.15
  @manager_user_id    Application.compile_env(:inventory, :warehouse_manager_id, "system")

  def reconcile(cycle_count_id, counted_lines) when is_list(counted_lines) do
    Logger.info("Reconciling cycle count=#{cycle_count_id}")

    case Repo.get(CycleCount, cycle_count_id) |> Repo.preload(:lines) do
      nil ->
        {:error, :cycle_count_not_found}

      %CycleCount{status: status} when status != :in_progress ->
        {:error, {:invalid_count_status, status}}

      %CycleCount{} = count ->
        # --- Index system lines ---
        system_index = Map.new(count.lines, &{&1.sku, &1.expected_qty})

        # --- Validate all counted SKUs belong to this count ---
        unknown_skus =
          counted_lines
          |> Enum.map(& &1.sku)
          |> Enum.reject(&Map.has_key?(system_index, &1))

        if unknown_skus != [] do
          {:error, {:unknown_skus_in_count, unknown_skus}}
        else
          # --- Compute variances ---
          variances =
            Enum.map(counted_lines, fn line ->
              expected = Map.get(system_index, line.sku, 0)
              counted  = line.counted_qty
              delta    = counted - expected

              severity =
                cond do
                  expected == 0 and delta != 0 ->
                    :flag
                  expected > 0 and abs(delta / expected) >= @variance_flag_pct ->
                    :flag
                  expected > 0 and abs(delta / expected) >= @variance_warn_pct ->
                    :warn
                  true ->
                    :ok
                end

              %{sku: line.sku, expected: expected, counted: counted, delta: delta, severity: severity}
            end)

          # --- Create stock adjustment records ---
          adjustments =
            variances
            |> Enum.reject(fn v -> v.delta == 0 end)
            |> Enum.map(fn v ->
              {:ok, adj} =
                Repo.insert(StockAdjustment.changeset(%StockAdjustment{}, %{
                  cycle_count_id: cycle_count_id,
                  sku: v.sku,
                  qty_before: v.expected,
                  qty_after: v.counted,
                  delta: v.delta,
                  reason: :cycle_count_reconciliation,
                  applied_at: DateTime.utc_now()
                }))
              adj
            end)

          # --- Update on-hand stock quantities ---
          Enum.each(variances, fn v ->
            case Repo.get_by(StockItem, sku: v.sku) do
              nil  -> :skip
              item ->
                item
                |> StockItem.changeset(%{on_hand: v.counted})
                |> Repo.update!()
            end
          end)

          # --- Spawn investigation tasks for flagged discrepancies ---
          flagged = Enum.filter(variances, &(&1.severity == :flag))

          Enum.each(flagged, fn v ->
            Repo.insert!(%InvestigationTask{
              cycle_count_id: cycle_count_id,
              sku: v.sku,
              expected_qty: v.expected,
              counted_qty: v.counted,
              delta: v.delta,
              status: :open,
              created_at: DateTime.utc_now()
            })
            Logger.warning("Investigation task created for SKU #{v.sku}: delta=#{v.delta}")
          end)

          # --- Close cycle count ---
          count
          |> CycleCount.changeset(%{
            status: :completed,
            completed_at: DateTime.utc_now(),
            total_skus_counted: length(counted_lines),
            total_adjustments: length(adjustments),
            flagged_count: length(flagged)
          })
          |> Repo.update!()

          # --- Notify warehouse manager ---
          Dispatcher.dispatch(@manager_user_id, %{
            type: "cycle_count_completed",
            payload: %{
              cycle_count_id: cycle_count_id,
              warehouse_id: count.warehouse_id,
              total_skus: length(counted_lines),
              adjustments: length(adjustments),
              flagged: length(flagged)
            }
          })

          Logger.info("Cycle count #{cycle_count_id} reconciled: #{length(adjustments)} adjustment(s), #{length(flagged)} flag(s)")
          {:ok, %{adjustments: adjustments, variances: variances, flagged: flagged}}
        end
    end
  end

  def reopen(cycle_count_id) do
    case Repo.get(CycleCount, cycle_count_id) do
      nil   -> {:error, :not_found}
      count -> count |> CycleCount.changeset(%{status: :in_progress}) |> Repo.update()
    end
  end
end
```
