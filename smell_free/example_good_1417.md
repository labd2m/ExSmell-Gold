```elixir
defmodule Ecommerce.Catalog.BundleBuilder do
  @moduledoc """
  Constructs product bundles with configurable discount rules.
  Bundles define required and optional components; pricing accounts for
  per-component overrides and bundle-level discount tiers.
  All monetary values are integer cents.
  """

  @type component :: %{
          product_id: String.t(),
          quantity: pos_integer(),
          unit_price_cents: pos_integer(),
          override_price_cents: pos_integer() | nil,
          required: boolean()
        }

  @type discount_tier :: %{
          min_components: pos_integer(),
          discount_pct: float()
        }

  @type bundle :: %{
          id: String.t(),
          name: String.t(),
          components: [component()],
          discount_tiers: [discount_tier()]
        }

  @type pricing :: %{
          subtotal_cents: non_neg_integer(),
          discount_pct: float(),
          discount_cents: non_neg_integer(),
          total_cents: non_neg_integer(),
          component_count: non_neg_integer()
        }

  @doc """
  Computes the final pricing for `bundle` given the selected `component_ids`.
  Only components with matching product IDs from the bundle definition are priced.
  Returns `{:ok, pricing}` or `{:error, reason}`.
  """
  @spec price(bundle(), [String.t()]) :: {:ok, pricing()} | {:error, String.t()}
  def price(%{components: components, discount_tiers: tiers} = _bundle, selected_ids)
      when is_list(selected_ids) do
    with :ok <- validate_required_components(components, selected_ids) do
      selected =
        components
        |> Enum.filter(fn c -> c.product_id in selected_ids end)

      subtotal = compute_subtotal(selected)
      count = length(selected)
      discount_pct = applicable_discount(tiers, count)
      discount_cents = round(subtotal * discount_pct / 100.0)
      total = max(subtotal - discount_cents, 0)

      {:ok,
       %{
         subtotal_cents: subtotal,
         discount_pct: discount_pct,
         discount_cents: discount_cents,
         total_cents: total,
         component_count: count
       }}
    end
  end

  @doc """
  Validates a bundle definition for structural correctness.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(bundle()) :: :ok | {:error, String.t()}
  def validate(%{id: id, name: name, components: components, discount_tiers: tiers})
      when is_binary(id) and id != "" and is_binary(name) and name != "" and
             is_list(components) and is_list(tiers) do
    with :ok <- validate_components(components),
         :ok <- validate_tiers(tiers) do
      :ok
    end
  end

  def validate(_bundle), do: {:error, "bundle must have id, name, components, and discount_tiers"}

  defp validate_required_components(components, selected_ids) do
    missing =
      components
      |> Enum.filter(fn c -> c.required end)
      |> Enum.reject(fn c -> c.product_id in selected_ids end)
      |> Enum.map(fn c -> c.product_id end)

    if missing == [] do
      :ok
    else
      {:error, "missing required components: #{Enum.join(missing, ", ")}"}
    end
  end

  defp compute_subtotal(components) do
    Enum.reduce(components, 0, fn c, acc ->
      unit_price = c.override_price_cents || c.unit_price_cents
      acc + unit_price * c.quantity
    end)
  end

  defp applicable_discount([], _count), do: 0.0

  defp applicable_discount(tiers, count) do
    tiers
    |> Enum.filter(fn t -> count >= t.min_components end)
    |> Enum.max_by(fn t -> t.discount_pct end, fn -> %{discount_pct: 0.0} end)
    |> Map.fetch!(:discount_pct)
  end

  defp validate_components([]), do: {:error, "bundle must have at least one component"}

  defp validate_components(components) do
    invalid = Enum.find(components, fn c -> not valid_component?(c) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid component: #{inspect(invalid)}"}
    end
  end

  defp valid_component?(%{product_id: pid, quantity: q, unit_price_cents: p, required: r})
       when is_binary(pid) and pid != "" and
              is_integer(q) and q > 0 and
              is_integer(p) and p > 0 and
              is_boolean(r),
       do: true

  defp valid_component?(_), do: false

  defp validate_tiers(tiers) do
    invalid = Enum.find(tiers, fn t -> not valid_tier?(t) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid discount tier: #{inspect(invalid)}"}
    end
  end

  defp valid_tier?(%{min_components: mc, discount_pct: dp})
       when is_integer(mc) and mc > 0 and
              is_float(dp) and dp >= 0.0 and dp <= 100.0,
       do: true

  defp valid_tier?(_), do: false
end
```
