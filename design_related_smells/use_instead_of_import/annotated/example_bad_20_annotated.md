# Annotated Bad Example 20

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Inventory.StockMonitor`, `use Inventory.ThresholdHelpers` directive
**Affected Functions:** `audit_warehouse/1`, `check_sku/2`, `reorder_candidates/1`, `generate_report/1`
**Explanation:** `Inventory.StockMonitor` uses `use Inventory.ThresholdHelpers` to obtain simple threshold-checking predicates. However, `ThresholdHelpers.__using__/1` also secretly injects an alias for `Inventory.AlertService` and sets `@low_stock_threshold`, `@critical_stock_threshold`, and `@reorder_lead_days` module attributes. The client module is unaware of these propagated dependencies. `import Inventory.ThresholdHelpers` would expose only the required predicate functions without hiding the `AlertService` alias and module attributes inside the macro expansion.

```elixir
defmodule Inventory.ThresholdHelpers do
  @moduledoc """
  Pure predicate and classification functions for stock level evaluation.
  No side-effects; suitable for use across multiple inventory contexts.
  """

  def below_threshold?(quantity, threshold) when is_integer(quantity) and is_integer(threshold) do
    quantity < threshold
  end

  def stock_status(quantity, low, critical) do
    cond do
      quantity <= 0       -> :out_of_stock
      quantity <= critical -> :critical
      quantity <= low      -> :low
      true                 -> :ok
    end
  end

  def days_of_stock(quantity, daily_velocity) when daily_velocity > 0 do
    Float.round(quantity / daily_velocity, 1)
  end

  def days_of_stock(_, _), do: :infinity

  def reorder_point(daily_velocity, lead_days, safety_stock \\ 0) do
    ceil(daily_velocity * lead_days) + safety_stock
  end

  def overstock?(quantity, max_capacity) when is_integer(quantity) and is_integer(max_capacity) do
    quantity > max_capacity
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 injects alias Inventory.AlertService
  # and three module attributes into every caller. The client never explicitly declared
  # a dependency on AlertService; this hidden propagation reduces readability and
  # makes the module's dependency surface opaque.
  defmacro __using__(_opts) do
    quote do
      import Inventory.ThresholdHelpers
      alias Inventory.AlertService

      @low_stock_threshold      20
      @critical_stock_threshold  5
      @reorder_lead_days         7
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Inventory.AlertService do
  @moduledoc "Dispatches stock-level alerts to operations teams (stub)."

  def send_low_stock_alert(sku, quantity) do
    IO.puts("[ALERT] Low stock for #{sku}: #{quantity} units remaining")
    :ok
  end

  def send_critical_alert(sku, quantity) do
    IO.puts("[CRITICAL] #{sku} nearly depleted: #{quantity} units")
    :ok
  end

  def send_out_of_stock_alert(sku) do
    IO.puts("[OUT-OF-STOCK] #{sku} is fully depleted!")
    :ok
  end
end

defmodule Inventory.StockMonitor do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Inventory.ThresholdHelpers` silently
  # brings AlertService into scope as an alias and injects @low_stock_threshold,
  # @critical_stock_threshold, and @reorder_lead_days without any explicit
  # declaration in this module. A reader has no indication of these dependencies
  # without diving into ThresholdHelpers.__using__/1. Using
  # `import Inventory.ThresholdHelpers` would be sufficient and transparent.
  use Inventory.ThresholdHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Monitors warehouse stock levels, triggers alerts for low or critical items,
  and produces reorder candidate lists for procurement workflows.
  """

  defstruct [:warehouse_id, :checked_at, :entries]

  def audit_warehouse(warehouse_id, stock_entries) when is_list(stock_entries) do
    checked = Enum.map(stock_entries, &check_sku(warehouse_id, &1))

    %__MODULE__{
      warehouse_id: warehouse_id,
      checked_at:   DateTime.utc_now(),
      entries:      checked
    }
  end

  def check_sku(_warehouse_id, %{sku: sku, quantity: qty, daily_velocity: vel} = entry) do
    status = stock_status(qty, @low_stock_threshold, @critical_stock_threshold)

    case status do
      :out_of_stock -> AlertService.send_out_of_stock_alert(sku)
      :critical     -> AlertService.send_critical_alert(sku, qty)
      :low          -> AlertService.send_low_stock_alert(sku, qty)
      :ok           -> :noop
    end

    Map.merge(entry, %{
      status:        status,
      days_of_stock: days_of_stock(qty, vel),
      reorder_point: reorder_point(vel, @reorder_lead_days)
    })
  end

  def reorder_candidates(%__MODULE__{entries: entries}) do
    entries
    |> Enum.filter(fn e -> e.status in [:low, :critical, :out_of_stock] end)
    |> Enum.sort_by(fn e -> e.quantity end)
    |> Enum.map(fn e ->
      %{
        sku:            e.sku,
        current_qty:    e.quantity,
        status:         e.status,
        reorder_point:  e.reorder_point,
        suggested_qty:  max(e.reorder_point * 2 - e.quantity, 0)
      }
    end)
  end

  def generate_report(%__MODULE__{} = audit) do
    candidates = reorder_candidates(audit)
    ok_count   = Enum.count(audit.entries, &(&1.status == :ok))
    alert_count = length(candidates)

    """
    Warehouse Audit Report
    Warehouse  : #{audit.warehouse_id}
    Audited At : #{audit.checked_at}
    Items OK   : #{ok_count}
    Items Alert: #{alert_count}
    ---
    Reorder Candidates:
    #{Enum.map_join(candidates, "\n", fn c -> "  #{c.sku} | #{c.status} | qty: #{c.current_qty} | suggest: #{c.suggested_qty}" end)}
    """
  end
end
```
