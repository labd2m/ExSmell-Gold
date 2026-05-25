```elixir
defmodule PackagingSelector do
  @moduledoc """
  Selects the appropriate packaging for outbound shipments based
  on product dimensions and weight. Calculates oversize surcharges
  and provides box dimension data for carrier manifests in a
  fulfilment warehouse system.
  """

  alias PackagingSelector.{Product, PackagingSpec, ShipmentManifest, CarrierRule}

  @type size_tier :: :small | :medium | :large | :oversize

  @spec select_packaging(Product.t()) :: {:ok, PackagingSpec.t()} | {:error, String.t()}
  def select_packaging(%Product{} = product) do
    tier = classify_tier(product)
    dims = box_dimensions_cm(tier)
    surcharge = oversize_surcharge(tier)

    if fits_in_box?(product, dims) do
      {:ok,
       %PackagingSpec{
         tier: tier,
         length_cm: dims.length,
         width_cm: dims.width,
         height_cm: dims.height,
         oversize_surcharge: surcharge,
         label: size_tier_label(tier)
       }}
    else
      {:error, "product #{product.sku} does not fit in any standard packaging tier"}
    end
  end

  @spec build_manifest_line(Product.t(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def build_manifest_line(%Product{} = product, quantity) do
    with {:ok, spec} <- select_packaging(product) do
      {:ok,
       %{
         sku: product.sku,
         quantity: quantity,
         packaging_tier: spec.tier,
         box_dims: box_dimensions_cm(spec.tier),
         unit_surcharge: spec.oversize_surcharge,
         total_surcharge: spec.oversize_surcharge * quantity
       }}
    end
  end

  @spec estimate_packing_cost([Product.t()]) :: float()
  def estimate_packing_cost(products) do
    products
    |> Enum.map(fn product ->
      tier = classify_tier(product)
      oversize_surcharge(tier)
    end)
    |> Enum.sum()
    |> Float.round(2)
  end

  @spec classify_tier(Product.t()) :: size_tier()
  def classify_tier(%Product{length_cm: l, width_cm: w, height_cm: h, weight_kg: wt}) do
    girth = 2 * (w + h)
    longest = l

    cond do
      wt > 30 or longest + girth > 330 -> :oversize
      wt > 10 or longest > 60           -> :large
      wt > 2 or longest > 30            -> :medium
      true                               -> :small
    end
  end

  @spec box_dimensions_cm(size_tier()) :: map()
  def box_dimensions_cm(tier) do
    case tier do
      :small    -> %{length: 20, width: 15, height: 10}
      :medium   -> %{length: 40, width: 30, height: 20}
      :large    -> %{length: 60, width: 45, height: 35}
      :oversize -> %{length: 120, width: 80, height: 60}
    end
  end

  @spec oversize_surcharge(size_tier()) :: float()
  def oversize_surcharge(tier) do
    case tier do
      :small    -> 0.00
      :medium   -> 0.00
      :large    -> 3.50
      :oversize -> 18.00
    end
  end

  @spec fits_in_box?(Product.t(), map()) :: boolean()
  defp fits_in_box?(%Product{length_cm: l, width_cm: w, height_cm: h}, dims) do
    l <= dims.length and w <= dims.width and h <= dims.height
  end

  @spec size_tier_label(size_tier()) :: String.t()
  defp size_tier_label(tier) do
    tier |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @spec all_tiers() :: [size_tier()]
  def all_tiers, do: [:small, :medium, :large, :oversize]
end
```
