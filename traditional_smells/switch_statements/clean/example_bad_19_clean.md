```elixir
defmodule DiscountEngine do
  @moduledoc """
  Applies promotional discounts to billing orders. Handles percentage-based,
  fixed-amount, free-shipping, and buy-X-get-Y discount mechanics in the
  billing and promotions subsystem.
  """

  require Logger

  @discount_types [:percentage, :fixed_amount, :free_shipping, :buy_x_get_y]

  def valid_discount_types, do: @discount_types







  @doc """
  Applies the discount to the given order, returning an updated order map
  with the discounted total and a line detailing the reduction applied.
  """
  def apply_discount(%{discount_type: discount_type} = discount, %{total_cents: total} = order) do
    {reduction, notes} =
      case discount_type do
        :percentage ->
          pct = discount.value
          reduction = trunc(total * (pct / 100.0))
          {reduction, "#{pct}% discount applied"}

        :fixed_amount ->
          reduction = min(discount.value, total)
          {reduction, "$#{reduction / 100.0} discount applied"}

        :free_shipping ->
          shipping = Map.get(order, :shipping_cents, 0)
          {shipping, "Free shipping applied"}

        :buy_x_get_y ->
          qty = Map.get(order, :quantity, 1)
          free_units = div(qty, discount.buy_quantity)
          unit_price = Map.get(order, :unit_price_cents, 0)
          {free_units * unit_price, "#{free_units} free unit(s) applied"}
      end

    new_total = max(0, total - reduction)

    {:ok,
     order
     |> Map.put(:total_cents, new_total)
     |> Map.put(:discount_reduction_cents, reduction)
     |> Map.put(:discount_notes, notes)}
  end

  @doc """
  Returns a customer-readable summary string describing the discount.
  """
  def discount_summary(%{discount_type: discount_type} = discount) do
    case discount_type do
      :percentage ->
        "#{discount.value}% off your order"

      :fixed_amount ->
        amount_str = "$#{:erlang.float_to_binary(discount.value / 100.0, decimals: 2)}"
        "#{amount_str} off your order"

      :free_shipping ->
        "Free shipping on this order"

      :buy_x_get_y ->
        "Buy #{discount.buy_quantity}, get #{discount.get_quantity} free"
    end
  end

  @doc """
  Returns true when the discount type may be stacked with other discounts
  on the same order.
  """
  def combinable?(%{discount_type: discount_type}) do
    case discount_type do
      :percentage -> false
      :fixed_amount -> true
      :free_shipping -> true
      :buy_x_get_y -> false
      _ -> false
    end
  end



  @doc """
  Applies a list of eligible discounts to an order, respecting combinability rules.
  Non-combinable discounts take the one with the greatest reduction.
  """
  def apply_all(discounts, order) when is_list(discounts) do
    {combinables, non_combinables} = Enum.split_with(discounts, &combinable?/1)

    best_non_combinable =
      non_combinables
      |> Enum.map(fn d ->
        case apply_discount(d, order) do
          {:ok, updated} -> {d, updated.discount_reduction_cents}
          _ -> {d, 0}
        end
      end)
      |> Enum.max_by(fn {_d, reduction} -> reduction end, fn -> nil end)

    discounts_to_apply =
      combinables ++
        case best_non_combinable do
          nil -> []
          {d, _} -> [d]
        end

    Enum.reduce(discounts_to_apply, {:ok, order}, fn discount, {:ok, current_order} ->
      apply_discount(discount, current_order)
    end)
  end

  @doc """
  Validates that a discount struct has the fields required for its type.
  """
  def validate(%{discount_type: :percentage, value: v} = d) when v > 0 and v <= 100,
    do: {:ok, d}

  def validate(%{discount_type: :fixed_amount, value: v} = d) when v > 0, do: {:ok, d}
  def validate(%{discount_type: :free_shipping} = d), do: {:ok, d}

  def validate(%{discount_type: :buy_x_get_y, buy_quantity: bq, get_quantity: gq} = d)
      when is_integer(bq) and bq > 0 and is_integer(gq) and gq > 0,
      do: {:ok, d}

  def validate(%{discount_type: type}), do: {:error, {:invalid_discount, type}}
  def validate(_), do: {:error, :missing_discount_type}
end
```
