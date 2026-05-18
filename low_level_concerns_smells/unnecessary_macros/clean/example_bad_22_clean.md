```elixir
defmodule Inventory.QueryUtils do
  @moduledoc """
  Enumerable query helpers used to aggregate and analyse inventory
  datasets in memory before committing to persistence or reporting.
  """

  defmacro count_by(items, key_fn) do
    quote do
      unquote(items)
      |> Enum.group_by(unquote(key_fn))
      |> Map.new(fn {k, v} -> {k, length(v)} end)
    end
  end

  @doc """
  Returns the total quantity across all items in a list.
  """
  @spec total_quantity(list(map())) :: non_neg_integer()
  def total_quantity(items) do
    Enum.reduce(items, 0, &(&1.quantity + &2))
  end

  @doc """
  Filters items whose quantity is below the given threshold.
  """
  @spec below_threshold(list(map()), non_neg_integer()) :: list(map())
  def below_threshold(items, threshold) do
    Enum.filter(items, &(&1.quantity < threshold))
  end

  @doc """
  Returns the top N items by quantity, descending.
  """
  @spec top_n(list(map()), pos_integer()) :: list(map())
  def top_n(items, n) do
    items
    |> Enum.sort_by(& &1.quantity, :desc)
    |> Enum.take(n)
  end
end

defmodule Inventory.StockAuditService do
  @moduledoc """
  Performs stock audit operations: summarising discrepancies, counting
  items by category and warehouse, and flagging anomalies for review.
  """

  require Inventory.QueryUtils

  alias Inventory.QueryUtils

  @discrepancy_threshold 5

  @doc """
  Builds a full audit summary from a list of scanned stock records.
  Counts items per category, warehouse, and discrepancy severity.
  """
  @spec build_audit_summary(list(map())) :: map()
  def build_audit_summary(records) do
    discrepancies = Enum.filter(records, fn r ->
      abs(r.scanned_quantity - r.expected_quantity) > 0
    end)

    %{
      total_records: length(records),
      total_discrepancies: length(discrepancies),
      by_category: QueryUtils.count_by(records, & &1.category),
      by_warehouse: QueryUtils.count_by(records, & &1.warehouse_id),
      discrepancies_by_severity: QueryUtils.count_by(discrepancies, &severity_label/1),
      flagged_for_review: Enum.filter(discrepancies, fn r ->
        abs(r.scanned_quantity - r.expected_quantity) >= @discrepancy_threshold
      end),
      generated_at: DateTime.utc_now()
    }
  end

  @doc """
  Computes per-category stock health metrics from a list of records.
  """
  @spec category_health(list(map())) :: list(map())
  def category_health(records) do
    records
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, items} ->
      total = QueryUtils.total_quantity(items)
      low_stock = QueryUtils.below_threshold(items, 10)

      %{
        category: category,
        sku_count: length(items),
        total_quantity: total,
        low_stock_count: length(low_stock),
        top_items: QueryUtils.top_n(items, 3)
      }
    end)
    |> Enum.sort_by(& &1.category)
  end

  defp severity_label(%{scanned_quantity: scanned, expected_quantity: expected}) do
    diff = abs(scanned - expected)

    cond do
      diff >= 50 -> :critical
      diff >= 20 -> :high
      diff >= 5 -> :medium
      true -> :low
    end
  end
end
```
