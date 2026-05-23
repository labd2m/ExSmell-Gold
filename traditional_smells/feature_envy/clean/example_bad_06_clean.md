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
