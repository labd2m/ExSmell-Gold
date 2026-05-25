# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `WarehousePolicy.storage_requirements/1` and `WarehousePolicy.handling_fee_per_unit/1`
- **Affected functions:** `storage_requirements/1`, `handling_fee_per_unit/1`
- **Short explanation:** The same `case` branching over product category (`:ambient`, `:chilled`, `:frozen`, `:hazardous`, `:fragile`) is duplicated in `storage_requirements/1` and `handling_fee_per_unit/1`. Adding a new category forces edits in both functions.

---

```elixir
defmodule WarehousePolicy do
  @moduledoc """
  Defines category-specific storage requirements and handling fees
  for incoming products in a third-party logistics (3PL) warehouse
  management system. Governs putaway rules and cost modelling.
  """

  alias WarehousePolicy.{
    Product,
    InboundShipment,
    PutawayInstruction,
    CostEstimate
  }

  @type product_category :: :ambient | :chilled | :frozen | :hazardous | :fragile

  @spec process_inbound(InboundShipment.t()) ::
          {:ok, [PutawayInstruction.t()]} | {:error, String.t()}
  def process_inbound(%InboundShipment{} = shipment) do
    instructions =
      Enum.map(shipment.line_items, fn item ->
        requirements = storage_requirements(item.product.category)

        %PutawayInstruction{
          product_id: item.product.id,
          quantity: item.quantity,
          zone: requirements.zone,
          temperature_range: requirements.temperature_range,
          requires_hazmat_cert: requirements.hazmat_cert,
          handling_fee: handling_fee_per_unit(item.product.category) * item.quantity
        }
      end)

    {:ok, instructions}
  end

  @spec estimate_storage_cost(Product.t(), integer(), integer()) :: CostEstimate.t()
  def estimate_storage_cost(%Product{} = product, quantity, days) do
    reqs = storage_requirements(product.category)
    fee_per_unit = handling_fee_per_unit(product.category)
    daily_rate = reqs.daily_rate_per_unit
    total = Float.round(quantity * (fee_per_unit + daily_rate * days), 2)

    %CostEstimate{
      product_id: product.id,
      quantity: quantity,
      days: days,
      handling_fee: fee_per_unit * quantity,
      storage_fee: daily_rate * quantity * days,
      total: total
    }
  end

  @spec requires_special_handling?(product_category()) :: boolean()
  def requires_special_handling?(category) do
    category in [:hazardous, :fragile, :frozen]
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `category`
  # also appears in `handling_fee_per_unit/1` below. Both enumerate :ambient,
  # :chilled, :frozen, :hazardous, :fragile — a new category requires edits in both.
  @spec storage_requirements(product_category()) :: map()
  def storage_requirements(category) do
    case category do
      :ambient ->
        %{zone: "A", temperature_range: {15, 25}, hazmat_cert: false, daily_rate_per_unit: 0.05}

      :chilled ->
        %{zone: "C", temperature_range: {2, 8}, hazmat_cert: false, daily_rate_per_unit: 0.15}

      :frozen ->
        %{zone: "F", temperature_range: {-25, -18}, hazmat_cert: false, daily_rate_per_unit: 0.25}

      :hazardous ->
        %{zone: "H", temperature_range: {15, 25}, hazmat_cert: true, daily_rate_per_unit: 0.40}

      :fragile ->
        %{zone: "G", temperature_range: {15, 25}, hazmat_cert: false, daily_rate_per_unit: 0.20}
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `category`
  # already appeared in `storage_requirements/1` above. All five product category
  # atoms are repeated, so evolving the category taxonomy requires touching both.
  @spec handling_fee_per_unit(product_category()) :: float()
  def handling_fee_per_unit(category) do
    case category do
      :ambient   -> 0.10
      :chilled   -> 0.30
      :frozen    -> 0.50
      :hazardous -> 1.20
      :fragile   -> 0.75
    end
  end
  # VALIDATION: SMELL END

  @spec validate_category(atom()) :: :ok | {:error, String.t()}
  def validate_category(category) do
    valid = [:ambient, :chilled, :frozen, :hazardous, :fragile]

    if category in valid do
      :ok
    else
      {:error, "unknown product category: #{category}"}
    end
  end

  @spec compliance_checklist(product_category()) :: [String.t()]
  def compliance_checklist(:hazardous) do
    ["Verify SDS sheets", "Check IATA classification", "Confirm staff hazmat certification"]
  end

  def compliance_checklist(:frozen) do
    ["Verify cold-chain integrity", "Check temperature log on arrival"]
  end

  def compliance_checklist(_), do: ["Standard receiving inspection"]
end
```
