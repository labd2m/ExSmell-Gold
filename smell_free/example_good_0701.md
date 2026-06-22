# File: `example_good_701.md`

```elixir
defmodule Catalog.BundleComposer do
  @moduledoc """
  Composes product bundles from constituent SKUs, applying bundle-level
  pricing rules on top of individual component prices.

  Bundle discount strategies are expressed as plain value objects so
  callers can assemble them declaratively. All pricing arithmetic uses
  integer cents; no floating-point rounding accumulates across components.
  """

  @type sku :: String.t()
  @type amount_cents :: non_neg_integer()

  @type component :: %{
          required(:sku) => sku(),
          required(:quantity) => pos_integer(),
          required(:unit_price_cents) => amount_cents()
        }

  @type discount_rule ::
          {:percentage_off, float()}
          | {:fixed_off_cents, amount_cents()}
          | {:fixed_bundle_price_cents, amount_cents()}

  @type bundle_spec :: %{
          required(:name) => String.t(),
          required(:components) => [component()],
          required(:discount) => discount_rule()
        }

  @type bundle_result :: %{
          name: String.t(),
          components: [component()],
          component_total_cents: amount_cents(),
          discount_cents: amount_cents(),
          bundle_price_cents: amount_cents(),
          savings_cents: amount_cents()
        }

  @doc """
  Computes the final price and savings for a bundle specification.

  Returns `{:ok, bundle_result}` or `{:error, reason}` when the
  spec is invalid (e.g. empty component list or negative discount).
  """
  @spec compose(bundle_spec()) :: {:ok, bundle_result()} | {:error, atom()}
  def compose(%{name: name, components: components, discount: discount})
      when is_binary(name) and is_list(components) do
    with :ok <- validate_components(components),
         {:ok, discount_cents, bundle_price} <- apply_discount(components, discount) do
      component_total = sum_component_total(components)

      {:ok, %{
        name: name,
        components: components,
        component_total_cents: component_total,
        discount_cents: discount_cents,
        bundle_price_cents: bundle_price,
        savings_cents: component_total - bundle_price
      }}
    end
  end

  @doc """
  Returns the total undiscounted price of a list of components.
  """
  @spec component_total([component()]) :: amount_cents()
  def component_total(components) when is_list(components) do
    sum_component_total(components)
  end

  @doc """
  Returns `true` when all listed SKUs are present in the component list.
  """
  @spec contains_all_skus?(bundle_spec(), [sku()]) :: boolean()
  def contains_all_skus?(%{components: components}, required_skus) do
    present = MapSet.new(components, & &1.sku)
    Enum.all?(required_skus, &MapSet.member?(present, &1))
  end

  @doc """
  Substitutes the component for `sku` with a new component definition,
  recalculating pricing. Returns `{:error, :sku_not_found}` if the SKU
  is not in the bundle.
  """
  @spec substitute(bundle_spec(), sku(), component()) ::
          {:ok, bundle_spec()} | {:error, :sku_not_found}
  def substitute(%{components: components} = spec, sku, new_component)
      when is_binary(sku) do
    if Enum.any?(components, &(&1.sku == sku)) do
      new_components = Enum.map(components, fn c ->
        if c.sku == sku, do: new_component, else: c
      end)

      {:ok, %{spec | components: new_components}}
    else
      {:error, :sku_not_found}
    end
  end

  defp validate_components([]), do: {:error, :empty_bundle}

  defp validate_components(components) do
    invalid = Enum.find(components, fn c ->
      not (is_integer(c.quantity) and c.quantity > 0 and
           is_integer(c.unit_price_cents) and c.unit_price_cents >= 0)
    end)

    if invalid, do: {:error, :invalid_component}, else: :ok
  end

  defp apply_discount(components, {:percentage_off, pct})
       when is_float(pct) and pct > 0.0 and pct <= 100.0 do
    total = sum_component_total(components)
    discount = round(total * pct / 100.0)
    {:ok, discount, total - discount}
  end

  defp apply_discount(components, {:fixed_off_cents, amount})
       when is_integer(amount) and amount >= 0 do
    total = sum_component_total(components)
    discount = min(amount, total)
    {:ok, discount, total - discount}
  end

  defp apply_discount(components, {:fixed_bundle_price_cents, price})
       when is_integer(price) and price >= 0 do
    total = sum_component_total(components)
    discount = max(total - price, 0)
    {:ok, discount, price}
  end

  defp apply_discount(_components, _unknown), do: {:error, :invalid_discount_rule}

  defp sum_component_total(components) do
    Enum.sum(Enum.map(components, fn c -> c.quantity * c.unit_price_cents end))
  end
end
```
