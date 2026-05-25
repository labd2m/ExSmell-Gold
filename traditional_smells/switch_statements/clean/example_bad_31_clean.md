```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages product inventory levels, reorder triggers, and
  stock alert classifications for a warehouse management system.
  """

  alias InventoryManager.{Product, PurchaseOrder, Supplier, AuditTrail}

  @critical_threshold 10
  @low_threshold 25
  @adequate_threshold 100

  @spec evaluate_stock(Product.t()) :: map()
  def evaluate_stock(%Product{} = product) do
    %{
      product_id: product.id,
      sku: product.sku,
      quantity_on_hand: product.quantity_on_hand,
      alert_level: stock_alert_level(product),
      reorder_qty: reorder_quantity(product),
      should_reorder: should_trigger_reorder?(product)
    }
  end

  @spec process_reorder_sweep([Product.t()]) :: {:ok, [PurchaseOrder.t()]}
  def process_reorder_sweep(products) do
    orders =
      products
      |> Enum.filter(&should_trigger_reorder?/1)
      |> Enum.map(fn product ->
        qty = reorder_quantity(product)
        supplier = Supplier.primary_for_product!(product.id)
        create_purchase_order(product, supplier, qty)
      end)

    {:ok, orders}
  end





  @spec stock_alert_level(Product.t()) :: :critical | :low | :adequate | :optimal
  def stock_alert_level(%Product{quantity_on_hand: qty}) do
    cond do
      qty <= @critical_threshold  -> :critical
      qty <= @low_threshold       -> :low
      qty <= @adequate_threshold  -> :adequate
      true                        -> :optimal
    end
  end


  @spec should_trigger_reorder?(Product.t()) :: boolean()
  def should_trigger_reorder?(%Product{} = product) do
    stock_alert_level(product) in [:critical, :low]
  end





  @spec reorder_quantity(Product.t()) :: integer()
  def reorder_quantity(%Product{quantity_on_hand: qty, max_stock_level: max_stock}) do
    cond do
      qty <= @critical_threshold -> max_stock
      qty <= @low_threshold      -> div(max_stock, 2)
      qty <= @adequate_threshold -> div(max_stock, 4)
      true                       -> 0
    end
  end


  @spec adjust_stock(Product.t(), integer(), String.t()) ::
          {:ok, Product.t()} | {:error, String.t()}
  def adjust_stock(%Product{} = product, delta, reason) do
    new_qty = product.quantity_on_hand + delta

    if new_qty < 0 do
      {:error, "stock adjustment would result in negative inventory"}
    else
      updated = %{product | quantity_on_hand: new_qty}
      AuditTrail.log(:stock_adjustment, product.id, %{delta: delta, reason: reason})
      {:ok, updated}
    end
  end

  @spec create_purchase_order(Product.t(), Supplier.t(), integer()) :: PurchaseOrder.t()
  defp create_purchase_order(%Product{} = product, %Supplier{} = supplier, quantity) do
    %PurchaseOrder{
      product_id: product.id,
      supplier_id: supplier.id,
      quantity: quantity,
      unit_cost: supplier.unit_cost,
      status: :pending,
      created_at: DateTime.utc_now()
    }
  end
end
```
