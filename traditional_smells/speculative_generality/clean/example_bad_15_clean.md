```elixir
defmodule Inventory.PricingAdjuster do
  @moduledoc """
  Applies dynamic pricing rules and margin adjustments to products
  in the inventory catalogue. Coordinates with cost data and seasonal
  multipliers to produce the final shelf price for each SKU.
  """

  alias Inventory.{Product, PriceHistory, CostRecord, Repo}

  @default_markup        0.12
  @seasonal_peak_factor  1.10
  @clearance_factor      0.75
  @min_margin_rate       0.05

  def compute_adjusted_price(%Product{product_line: product_line} = product) do
    cost   = fetch_latest_cost(product.sku)
    factor = seasonal_factor(product.sku)

    markup =
      case product_line do
        _ -> @default_markup
      end

    base_price = Float.round(cost * (1 + markup) * factor, 2)

    if margin_acceptable?(cost, base_price) do
      {:ok, base_price}
    else
      {:error, :margin_too_low}
    end
  end

  def apply_clearance(product_id) do
    product      = Repo.get!(Product, product_id)
    current_cost = fetch_latest_cost(product.sku)
    new_price    = Float.round(product.price * @clearance_factor, 2)

    if new_price < current_cost * (1 + @min_margin_rate) do
      {:error, :clearance_below_minimum_margin}
    else
      update_price(product, new_price, :clearance)
    end
  end

  def bulk_reprice(product_ids) when is_list(product_ids) do
    results =
      Enum.map(product_ids, fn id ->
        product = Repo.get!(Product, id)

        case compute_adjusted_price(product) do
          {:ok, new_price} ->
            case update_price(product, new_price, :auto_adjustment) do
              {:ok, updated} -> {:ok, updated}
              {:error, e}    -> {:error, e}
            end

          {:error, reason} ->
            {:error, {id, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, p} -> p end)}
    else
      {:partial, results}
    end
  end

  def price_history(sku, limit \\ 20) do
    PriceHistory
    |> Repo.all()
    |> Enum.filter(&(&1.sku == sku))
    |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def margin_report(product_ids) do
    Enum.map(product_ids, fn id ->
      product = Repo.get!(Product, id)
      cost    = fetch_latest_cost(product.sku)
      margin  = Float.round((product.price - cost) / product.price * 100, 1)
      %{id: id, sku: product.sku, price: product.price, cost: cost, margin_pct: margin}
    end)
  end

  def lock_price(product_id) do
    product = Repo.get!(Product, product_id)

    product
    |> Product.changeset(%{price_locked: true, locked_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def unlock_price(product_id) do
    product = Repo.get!(Product, product_id)

    product
    |> Product.changeset(%{price_locked: false, locked_at: nil})
    |> Repo.update()
  end


  defp fetch_latest_cost(sku) do
    CostRecord
    |> Repo.all()
    |> Enum.filter(&(&1.sku == sku))
    |> Enum.max_by(& &1.recorded_at, DateTime, fn -> nil end)
    |> case do
      nil    -> raise "No cost record found for SKU #{sku}"
      record -> record.unit_cost
    end
  end

  defp seasonal_factor(_sku) do
    month = Date.utc_today().month
    if month in [11, 12], do: @seasonal_peak_factor, else: 1.0
  end

  defp margin_acceptable?(cost, price) do
    price > 0 and (price - cost) / price >= @min_margin_rate
  end

  defp update_price(product, new_price, reason) do
    Repo.insert!(%PriceHistory{
      sku:         product.sku,
      old_price:   product.price,
      new_price:   new_price,
      reason:      reason,
      recorded_at: DateTime.utc_now()
    })

    product
    |> Product.changeset(%{price: new_price, last_repriced_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
```
