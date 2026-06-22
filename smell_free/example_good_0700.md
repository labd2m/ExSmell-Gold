```elixir
defmodule Commerce.PromotionEngine do
  @moduledoc """
  Applies promotion codes to cart line items. Promotions support
  percentage discounts, fixed-amount discounts, and free-item grants.
  Each promotion carries eligibility conditions (minimum cart value,
  eligible SKUs, valid date range). The engine validates applicability
  before computing the discount so callers receive clear rejection reasons
  rather than silent zero-discount results.
  """

  @type promo_type :: :percentage | :fixed_cents | :free_item
  @type line_item :: %{sku: String.t(), quantity: pos_integer(), unit_price_cents: pos_integer()}
  @type promotion :: %{
          code: String.t(),
          type: promo_type(),
          value: number(),
          min_cart_cents: non_neg_integer(),
          eligible_skus: [String.t()] | :all,
          valid_from: Date.t(),
          valid_until: Date.t(),
          max_uses: pos_integer() | :unlimited
        }

  @type discount :: %{
          type: promo_type(),
          amount_cents: non_neg_integer(),
          description: String.t()
        }

  @type apply_result ::
          {:ok, discount()} | {:error, :expired | :not_yet_valid | :below_minimum | :no_eligible_items}

  @doc """
  Applies `promotion` to `line_items` on `reference_date`. Returns the
  computed discount or a typed rejection reason.
  """
  @spec apply(promotion(), [line_item()], Date.t()) :: apply_result()
  def apply(promotion, line_items, reference_date \ Date.utc_today())
      when is_map(promotion) and is_list(line_items) do
    with :ok <- check_date_validity(promotion, reference_date),
         :ok <- check_minimum_value(promotion, line_items) do
      eligible = eligible_items(promotion, line_items)

      if Enum.empty?(eligible) do
        {:error, :no_eligible_items}
      else
        {:ok, compute_discount(promotion, eligible)}
      end
    end
  end

  @doc "Returns the cart subtotal in cents for a list of line items."
  @spec cart_total([ line_item()]) :: non_neg_integer()
  def cart_total(line_items) when is_list(line_items) do
    Enum.sum_by(line_items, fn i -> i.unit_price_cents * i.quantity end)
  end

  defp check_date_validity(%{valid_from: from, valid_until: until}, today) do
    cond do
      Date.compare(today, from) == :lt -> {:error, :not_yet_valid}
      Date.compare(today, until) == :gt -> {:error, :expired}
      true -> :ok
    end
  end

  defp check_minimum_value(%{min_cart_cents: min}, line_items) do
    if cart_total(line_items) >= min, do: :ok, else: {:error, :below_minimum}
  end

  defp eligible_items(%{eligible_skus: :all}, items), do: items

  defp eligible_items(%{eligible_skus: skus}, items) when is_list(skus) do
    Enum.filter(items, fn item -> item.sku in skus end)
  end

  defp compute_discount(%{type: :percentage, value: pct}, eligible) do
    subtotal = cart_total(eligible)
    amount = round(subtotal * pct / 100)
    %{type: :percentage, amount_cents: amount, description: "#{pct}% off eligible items"}
  end

  defp compute_discount(%{type: :fixed_cents, value: fixed}, eligible) do
    subtotal = cart_total(eligible)
    amount = min(fixed, subtotal)
    %{type: :fixed_cents, amount_cents: trunc(amount), description: "#{format_cents(trunc(amount))} off"}
  end

  defp compute_discount(%{type: :free_item}, eligible) do
    cheapest = Enum.min_by(eligible, & &1.unit_price_cents)
    %{type: :free_item, amount_cents: cheapest.unit_price_cents,
      description: "Free #{cheapest.sku}"}
  end

  defp format_cents(cents) do
    "$#{div(cents, 100)}.#{rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
```
