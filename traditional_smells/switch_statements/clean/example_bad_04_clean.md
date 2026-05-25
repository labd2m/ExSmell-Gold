```elixir
defmodule InventoryPolicy do
  @moduledoc """
  Encodes business rules around inventory management: reorder thresholds,
  warehouse storage zones, expiry alerting windows, and stock audit cycles
  — organized by product category.
  """

  require Logger

  @categories [:electronics, :perishable, :apparel, :pharmaceutical]

  def supported_categories, do: @categories







  @doc """
  Returns the minimum stock unit count below which a reorder must be triggered
  for products in the given category.
  """
  def reorder_threshold(%{category: category}) do
    case category do
      :electronics -> 25
      :perishable -> 100
      :apparel -> 50
      :pharmaceutical -> 200
      _ -> 30
    end
  end

  @doc """
  Returns the warehouse storage zone identifier appropriate for the product category.
  """
  def storage_zone(%{category: category}) do
    case category do
      :electronics -> "zone-b-secure"
      :perishable -> "zone-a-cold"
      :apparel -> "zone-c-general"
      :pharmaceutical -> "zone-d-regulated"
      _ -> "zone-c-general"
    end
  end

  @doc """
  Returns the number of days before product expiry at which a warning alert
  should be raised for the given category.
  """
  def expiry_alert_days(%{category: category}) do
    case category do
      :electronics -> 365
      :perishable -> 3
      :apparel -> 180
      :pharmaceutical -> 30
      _ -> 90
    end
  end



  @doc """
  Evaluates whether a product needs to be reordered based on current stock levels.
  """
  def needs_reorder?(%{current_stock: current_stock} = product) do
    threshold = reorder_threshold(product)
    current_stock < threshold
  end

  @doc """
  Computes the quantity to order in a restocking run, aiming to fill up to a
  target multiplier of the reorder threshold.
  """
  def suggested_reorder_quantity(product, target_multiplier \\ 3) do
    threshold = reorder_threshold(product)
    excess = max(0, product.current_stock - threshold)
    max(0, threshold * target_multiplier - excess)
  end

  @doc """
  Returns full warehouse placement instructions for a product, combining zone
  information with any special handling flags.
  """
  def placement_instructions(%{category: category} = product) do
    zone = storage_zone(product)

    special_handling =
      cond do
        category == :perishable and Map.get(product, :requires_freezing, false) -> [:freeze]
        category == :pharmaceutical and Map.get(product, :controlled_substance, false) -> [:lock]
        true -> []
      end

    %{zone: zone, special_handling: special_handling}
  end

  @doc """
  Builds a stock audit report for a list of products, flagging those that
  require immediate action.
  """
  def audit_stock(products) when is_list(products) do
    products
    |> Enum.map(fn product ->
      alert_days = expiry_alert_days(product)
      reorder = needs_reorder?(product)
      instructions = placement_instructions(product)
      expiry_date = Map.get(product, :expiry_date)

      expiry_warning =
        if expiry_date do
          days_left = Date.diff(expiry_date, Date.utc_today())
          days_left <= alert_days
        else
          false
        end

      %{
        product_id: product.id,
        name: product.name,
        category: product.category,
        needs_reorder: reorder,
        expiry_warning: expiry_warning,
        placement: instructions
      }
    end)
    |> tap(fn results ->
      flagged = Enum.count(results, &(&1.needs_reorder or &1.expiry_warning))
      Logger.info("Stock audit complete — #{flagged}/#{length(results)} products flagged.")
    end)
  end
end
```
