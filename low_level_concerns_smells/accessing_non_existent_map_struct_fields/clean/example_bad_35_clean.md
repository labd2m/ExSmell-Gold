```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages warehouse stock levels, triggers replenishment orders,
  and tracks movement history for auditing purposes.
  """

  require Logger

  @default_reorder_qty 100
  @movement_types [:inbound, :outbound, :adjustment, :write_off]

  @type product :: %{
          sku: String.t(),
          name: String.t(),
          current_stock: non_neg_integer(),
          unit_cost: float(),
          warehouse_id: String.t(),
          optional(:reorder_point) => non_neg_integer(),
          optional(:max_stock) => non_neg_integer(),
          optional(:supplier_id) => String.t(),
          optional(:lead_time_days) => pos_integer()
        }

  @type movement :: %{
          type: atom(),
          quantity: integer(),
          reference: String.t(),
          performed_at: DateTime.t()
        }

  @spec apply_movement(product(), movement()) ::
          {:ok, product()} | {:error, String.t()}
  def apply_movement(product, %{type: type}) when type not in @movement_types do
    {:error, "unknown movement type: #{type}"}
  end

  def apply_movement(product, movement) do
    new_stock = product.current_stock + movement.quantity

    if new_stock < 0 do
      {:error, "movement would result in negative stock for SKU #{product.sku}"}
    else
      updated = %{product | current_stock: new_stock}
      Logger.info("SKU=#{product.sku} stock moved from #{product.current_stock} to #{new_stock}")
      {:ok, updated}
    end
  end

  @spec replenish(product(), keyword()) ::
          {:ok, map()} | {:no_action, String.t()} | {:error, String.t()}
  def replenish(product, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    reorder_point = product[:reorder_point]
    max_stock     = product[:max_stock]
    supplier_id   = product[:supplier_id]

    cond do
      is_nil(supplier_id) ->
        {:error, "no supplier configured for SKU #{product.sku}"}

      not force and product.current_stock > reorder_point ->
        {:no_action, "stock level #{product.current_stock} above reorder point #{reorder_point}"}

      true ->
        qty = calculate_order_qty(product.current_stock, max_stock)
        issue_purchase_order(product, supplier_id, qty)
    end
  end

  defp calculate_order_qty(current, nil), do: @default_reorder_qty
  defp calculate_order_qty(current, max_stock) do
    max(max_stock - current, @default_reorder_qty)
  end

  defp issue_purchase_order(product, supplier_id, qty) do
    po = %{
      po_number:    generate_po_number(),
      sku:          product.sku,
      warehouse_id: product.warehouse_id,
      supplier_id:  supplier_id,
      quantity:     qty,
      unit_cost:    product.unit_cost,
      total_cost:   Float.round(qty * product.unit_cost, 2),
      requested_at: DateTime.utc_now()
    }

    Logger.info("PO issued: #{po.po_number} for #{qty} units of SKU #{product.sku}")
    {:ok, po}
  end

  @spec valuation(product()) :: float()
  def valuation(product) do
    Float.round(product.current_stock * product.unit_cost, 2)
  end

  @spec below_reorder_point?(product()) :: boolean()
  def below_reorder_point?(product) do
    case product[:reorder_point] do
      nil   -> false
      point -> product.current_stock <= point
    end
  end

  defp generate_po_number do
    "PO-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
