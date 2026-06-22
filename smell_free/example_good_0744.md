# File: `example_good_744.md`

```elixir
defmodule Commerce.PromotionEngine do
  @moduledoc """
  Validates and applies promotion codes to order totals, enforcing
  usage limits, expiry dates, minimum order values, and per-customer
  redemption caps.

  Validation is a pure pipeline that accumulates errors before any
  database writes, so callers receive a complete picture of failures.
  Application is transactional: the usage counter increments and the
  discount is recorded atomically.
  """

  import Ecto.Query, warn: false

  alias Commerce.{Promotion, PromotionRedemption, Repo}

  @type customer_id :: Ecto.UUID.t()
  @type order_id :: Ecto.UUID.t()
  @type amount_cents :: non_neg_integer()

  @type apply_result ::
          {:ok, %{discount_cents: amount_cents(), promotion: Promotion.t()}}
          | {:error, [String.t()]}

  @doc """
  Validates and applies `promo_code` to an order with the given total.

  All eligibility rules are checked before any write occurs. Returns
  `{:ok, %{discount_cents, promotion}}` or `{:error, reasons}` listing
  every violated rule.
  """
  @spec apply(String.t(), customer_id(), order_id(), amount_cents()) :: apply_result()
  def apply(promo_code, customer_id, order_id, order_total_cents)
      when is_binary(promo_code) and is_binary(customer_id) and
             is_binary(order_id) and is_integer(order_total_cents) do
    promo_code
    |> String.upcase()
    |> find_promotion()
    |> validate_all(customer_id, order_total_cents)
    |> record_redemption(customer_id, order_id, order_total_cents)
  end

  @doc """
  Returns the discount amount in cents that `promo_code` would apply
  to `order_total_cents` without committing any changes.

  Returns `{:ok, discount_cents}` or `{:error, reasons}`.
  """
  @spec preview(String.t(), customer_id(), amount_cents()) ::
          {:ok, amount_cents()} | {:error, [String.t()]}
  def preview(promo_code, customer_id, order_total_cents) do
    case promo_code |> String.upcase() |> find_promotion() |> validate_all(customer_id, order_total_cents) do
      {:ok, promotion} -> {:ok, compute_discount(promotion, order_total_cents)}
      {:error, _} = error -> error
    end
  end

  defp find_promotion({:error, _} = error), do: error

  defp find_promotion(code) do
    case Repo.get_by(Promotion, code: code, active: true) do
      nil -> {:error, ["promotion code is invalid or inactive"]}
      promotion -> {:ok, promotion}
    end
  end

  defp validate_all({:error, _} = error, _customer_id, _total), do: error

  defp validate_all({:ok, promotion}, customer_id, order_total_cents) do
    errors =
      []
      |> check_expiry(promotion)
      |> check_usage_limit(promotion)
      |> check_per_customer_limit(promotion, customer_id)
      |> check_minimum_order(promotion, order_total_cents)

    case errors do
      [] -> {:ok, promotion}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_expiry(errors, %Promotion{expires_at: nil}), do: errors

  defp check_expiry(errors, %Promotion{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :lt do
      ["promotion has expired" | errors]
    else
      errors
    end
  end

  defp check_usage_limit(errors, %Promotion{max_uses: nil}), do: errors

  defp check_usage_limit(errors, %Promotion{id: id, max_uses: max}) do
    used = Repo.aggregate(where(PromotionRedemption, [r], r.promotion_id == ^id), :count, :id)
    if used >= max, do: ["promotion usage limit reached" | errors], else: errors
  end

  defp check_per_customer_limit(errors, %Promotion{max_uses_per_customer: nil}, _cid), do: errors

  defp check_per_customer_limit(errors, %Promotion{id: id, max_uses_per_customer: max}, customer_id) do
    used =
      PromotionRedemption
      |> where([r], r.promotion_id == ^id and r.customer_id == ^customer_id)
      |> Repo.aggregate(:count, :id)

    if used >= max, do: ["you have already used this promotion #{max} time(s)" | errors], else: errors
  end

  defp check_minimum_order(errors, %Promotion{minimum_order_cents: nil}, _total), do: errors

  defp check_minimum_order(errors, %Promotion{minimum_order_cents: min}, total) do
    if total < min, do: ["minimum order of #{min} cents required" | errors], else: errors
  end

  defp record_redemption({:error, _} = error, _cid, _oid, _total), do: error

  defp record_redemption({:ok, promotion}, customer_id, order_id, order_total_cents) do
    discount_cents = compute_discount(promotion, order_total_cents)

    Repo.transaction(fn ->
      %{promotion_id: promotion.id, customer_id: customer_id,
        order_id: order_id, discount_cents: discount_cents}
      |> PromotionRedemption.changeset()
      |> Repo.insert!()

      %{discount_cents: discount_cents, promotion: promotion}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp compute_discount(%Promotion{discount_type: :percentage, discount_value: pct}, total) do
    round(total * pct / 100.0)
  end

  defp compute_discount(%Promotion{discount_type: :fixed, discount_value: amount}, total) do
    min(amount, total)
  end
end
```
