# Annotated Example 06: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Inventory.StockAudit.evaluate_product_status/1`
- **Affected Function(s)**: `evaluate_product_status/1`
- **Explanation**: `evaluate_product_status/1` exclusively uses functions and data from
  the `Product` module (`Product.current_stock/1`, `Product.reorder_point/1`,
  `Product.sku/1`, `Product.supplier_lead_days/1`, `Product.category/1`,
  `Product.unit_of_measure/1`). `StockAudit` contributes only two module-level
  threshold constants, while all domain data belongs to `Product`, making this function
  a better fit inside that module.

## Code

```elixir
defmodule Inventory.StockAudit do
  require Logger

  alias Inventory.{AuditRecord, AlertDispatcher}
  alias Inventory.Product

  @low_stock_threshold 10
  @critical_stock_threshold 3

  @doc """
  Runs a stock audit across all active products and generates a summary report.
  Dispatches alerts for products at low or critical levels.
  """
  def run_full_audit do
    products = Product.list_active()

    results =
      Enum.map(products, fn product ->
        status = evaluate_product_status(product)

        AuditRecord.create(%{
          product_id: product.id,
          status: status.level,
          current_stock: status.current_stock,
          reorder_point: status.reorder_point,
          audited_at: DateTime.utc_now()
        })

        if status.level in [:low, :critical] do
          AlertDispatcher.send_stock_alert(product.id, status)
        end

        status
      end)

    Logger.info("Stock audit complete. #{length(results)} products evaluated.")
    summarize_audit_results(results)
  end

  @doc """
  Audits a single product by ID and returns its current stock status map.
  """
  def audit_product(product_id) do
    product = Product.get!(product_id)
    evaluate_product_status(product)
  end

  @doc """
  Returns all products currently below their reorder point.
  """
  def list_reorder_candidates do
    Product.list_active()
    |> Enum.filter(fn p ->
      status = evaluate_product_status(p)
      status.level in [:low, :critical, :reorder]
    end)
    |> Enum.map(& &1.id)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because evaluate_product_status/1 exclusively uses functions
  # VALIDATION: and data from the Product module: Product.current_stock/1,
  # VALIDATION: Product.reorder_point/1, Product.sku/1, Product.supplier_lead_days/1,
  # VALIDATION: Product.category/1, and Product.unit_of_measure/1.
  # VALIDATION: StockAudit contributes only the @low_stock_threshold and
  # VALIDATION: @critical_stock_threshold constants, while all domain data belongs to Product,
  # VALIDATION: making this function a better fit inside the Product module.
  defp evaluate_product_status(product) do
    current_stock = Product.current_stock(product)
    reorder_point = Product.reorder_point(product)
    sku = Product.sku(product)
    lead_days = Product.supplier_lead_days(product)
    category = Product.category(product)
    unit = Product.unit_of_measure(product)

    level =
      cond do
        current_stock <= @critical_stock_threshold -> :critical
        current_stock <= @low_stock_threshold -> :low
        current_stock <= reorder_point -> :reorder
        true -> :ok
      end

    %{
      product_id: product.id,
      sku: sku,
      category: category,
      current_stock: current_stock,
      reorder_point: reorder_point,
      unit: unit,
      supplier_lead_days: lead_days,
      level: level
    }
  end
  # VALIDATION: SMELL END

  defp summarize_audit_results(results) do
    %{
      total_audited: length(results),
      critical: Enum.count(results, &(&1.level == :critical)),
      low: Enum.count(results, &(&1.level == :low)),
      reorder: Enum.count(results, &(&1.level == :reorder)),
      ok: Enum.count(results, &(&1.level == :ok))
    }
  end
end
```
