```elixir
defmodule Catalog.Pricing do
  @moduledoc """
  Computes product prices under different pricing models:
  standard, bulk-quantity, and membership-based.
  All prices are returned in USD cents.
  """

  alias Catalog.Repo
  alias Catalog.Product

  @bulk_tiers [
    {100, 0.20},
    {50, 0.15},
    {25, 0.10},
    {10, 0.05}
  ]

  @member_tiers [
    {:platinum, 0.25},
    {:gold, 0.18},
    {:silver, 0.10},
    {:bronze, 0.05}
  ]

  @doc """
  Returns the standard list price for a product in cents.
  """
  def list_price(product_id) do
    case Repo.get(Product, product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product.price_cents}
    end
  end

  @doc """
  Calculates the bulk price for a product at a given quantity.
  Returns the per-unit price in cents after applying the highest qualifying discount.
  """
  def bulk_price(product_id, quantity) when is_integer(quantity) and quantity > 0 do
    with {:ok, product} <- Repo.get(Product, product_id) |> wrap() do
      discount =
        @bulk_tiers
        |> Enum.find(fn {min_qty, _rate} -> quantity >= min_qty end)
        |> case do
          nil -> 0.0
          {_min, rate} -> rate
        end

      discounted = round(product.price_cents * (1.0 - discount))

      {:ok, %{unit_price_cents: discounted, total_cents: discounted * quantity, discount_rate: discount}}
    end
  end

  @doc """
  Calculates the membership price for a product given a membership tier.
  Returns the discounted price in cents.
  """
  def member_price(product_id, membership_tier) do
    with {:ok, product} <- Repo.get(Product, product_id) |> wrap() do
      discount =
        @member_tiers
        |> Enum.find(fn {tier, _rate} -> tier == membership_tier end)
        |> case do
          nil -> 0.0
          {_tier, rate} -> rate
        end

      discounted = round(product.price_cents * (1.0 - discount))

      {:ok, %{unit_price_cents: discounted, discount_rate: discount, tier: membership_tier}}
    end
  end

  @doc """
  Returns the best available price for a product given quantity and membership.
  """
  def best_price(product_id, quantity, membership_tier) do
    bulk = bulk_price(product_id, quantity)
    member = member_price(product_id, membership_tier)

    case {bulk, member} do
      {{:ok, b}, {:ok, m}} ->
        if b.unit_price_cents <= m.unit_price_cents, do: {:ok, b}, else: {:ok, m}

      {{:ok, _} = b, _} ->
        b

      {_, {:ok, _} = m} ->
        m

      _ ->
        {:error, :price_unavailable}
    end
  end

  defp wrap(nil), do: {:error, :not_found}
  defp wrap(product), do: {:ok, product}
end
```
