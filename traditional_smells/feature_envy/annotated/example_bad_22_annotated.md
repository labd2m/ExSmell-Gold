# Annotated Example – Bad Code (Feature Envy)

## Metadata

| Field | Value |
|---|---|
| **Smell** | Feature Envy |
| **Expected Smell Location** | `Inventory.StockAudit.evaluate_reorder_need/1` |
| **Affected Function(s)** | `evaluate_reorder_need/1` |
| **Explanation** | `evaluate_reorder_need/1` is defined in `Inventory.StockAudit` but all its data and helper calls come from `Inventory.WarehouseProduct` — calling `get!/1`, `available_units/1`, `reorder_threshold/1`, `reorder_quantity/1`, and `is_perishable?/1`. The function has no meaningful tie to `StockAudit` and should live in `WarehouseProduct`. |

```elixir
defmodule Inventory.WarehouseProduct do
  @moduledoc "Represents a SKU stored in a warehouse location."

  defstruct [
    :id,
    :sku,
    :name,
    :warehouse_id,
    :bin_location,
    :units_on_hand,
    :units_reserved,
    :reorder_point,
    :reorder_qty,
    :perishable,
    :expiry_date,
    :supplier_id,
    :unit_cost
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      sku: "PROD-0042",
      name: "Widget Pro XL",
      warehouse_id: "WH-EAST-1",
      bin_location: "A3-R2-B4",
      units_on_hand: 18,
      units_reserved: 5,
      reorder_point: 20,
      reorder_qty: 100,
      perishable: false,
      expiry_date: nil,
      supplier_id: "SUP-007",
      unit_cost: Decimal.new("4.75")
    }
  end

  def available_units(%__MODULE__{units_on_hand: on_hand, units_reserved: reserved}) do
    max(0, on_hand - reserved)
  end

  def reorder_threshold(%__MODULE__{reorder_point: rp}), do: rp

  def reorder_quantity(%__MODULE__{reorder_qty: qty}), do: qty

  def is_perishable?(%__MODULE__{perishable: true}), do: true
  def is_perishable?(_), do: false

  def nearing_expiry?(%__MODULE__{perishable: true, expiry_date: exp}) when not is_nil(exp) do
    Date.diff(exp, Date.utc_today()) <= 30
  end
  def nearing_expiry?(_), do: false

  def full_location_label(%__MODULE__{warehouse_id: wh, bin_location: bin}) do
    "#{wh} / #{bin}"
  end
end

defmodule Inventory.ReorderRequest do
  @moduledoc "A pending reorder request for a warehouse product."

  defstruct [:product_id, :supplier_id, :qty, :urgency, :created_at]

  def create(product_id, supplier_id, qty, urgency) do
    %__MODULE__{
      product_id: product_id,
      supplier_id: supplier_id,
      qty: qty,
      urgency: urgency,
      created_at: DateTime.utc_now()
    }
  end
end

defmodule Inventory.StockAudit do
  @moduledoc """
  Performs periodic stock-level audits across warehouse locations and
  triggers reorder requests when inventory drops below safe levels.
  """

  alias Inventory.{WarehouseProduct, ReorderRequest}
  require Logger

  @doc """
  Audits a list of product IDs and returns a list of reorder requests
  for any that require replenishment.
  """
  def run_audit(product_ids) do
    product_ids
    |> Enum.map(&evaluate_reorder_need/1)
    |> Enum.reject(&is_nil/1)
    |> tap(fn requests ->
      Logger.info("Audit complete. #{length(requests)} reorder request(s) generated.")
    end)
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because `evaluate_reorder_need/1` is defined inside
  # VALIDATION: `Inventory.StockAudit` but all logic is driven by `WarehouseProduct`:
  # VALIDATION: it calls `WarehouseProduct.get!/1`, `WarehouseProduct.available_units/1`,
  # VALIDATION: `WarehouseProduct.reorder_threshold/1`, `WarehouseProduct.reorder_quantity/1`,
  # VALIDATION: and `WarehouseProduct.is_perishable?/1`. Nothing in the function is
  # VALIDATION: specific to `StockAudit`; it should be moved to `WarehouseProduct`.
  defp evaluate_reorder_need(product_id) do
    product   = WarehouseProduct.get!(product_id)
    available = WarehouseProduct.available_units(product)
    threshold = WarehouseProduct.reorder_threshold(product)
    qty       = WarehouseProduct.reorder_quantity(product)
    perishable = WarehouseProduct.is_perishable?(product)

    cond do
      available <= 0 ->
        ReorderRequest.create(product.id, product.supplier_id, qty, :critical)

      available < threshold ->
        urgency = if perishable, do: :high, else: :normal
        ReorderRequest.create(product.id, product.supplier_id, qty, urgency)

      true ->
        nil
    end
  end
  # VALIDATION: SMELL END

  defp summarise_audit(requests) do
    %{
      total:    length(requests),
      critical: Enum.count(requests, &(&1.urgency == :critical)),
      high:     Enum.count(requests, &(&1.urgency == :high)),
      normal:   Enum.count(requests, &(&1.urgency == :normal))
    }
  end
end
```
