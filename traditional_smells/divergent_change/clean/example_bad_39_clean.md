```elixir
defmodule MyApp.PromotionEngine do
  @moduledoc """
  Manages promotional campaign lifecycle, cart-level discount evaluation,
  and redemption tracking for the storefront.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Promotion, CartDiscount, PromotionRedemption}
  import Ecto.Query



  @doc """
  Creates a new promotion campaign in draft state.
  """
  def create_promotion(attrs) do
    required = [:name, :discount_type, :discount_value, :starts_at, :ends_at]
    missing = Enum.reject(required, &Map.has_key?(attrs, &1))

    if missing != [] do
      {:error, {:missing_fields, missing}}
    else
      %Promotion{}
      |> Promotion.changeset(Map.put(attrs, :status, :draft))
      |> Repo.insert()
    end
  end

  @doc """
  Activates a draft promotion, making it available for cart evaluation.
  """
  def activate_promotion(%Promotion{status: :draft} = promo) do
    promo
    |> Promotion.changeset(%{status: :active, activated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def activate_promotion(%Promotion{}), do: {:error, :only_draft_can_be_activated}

  @doc """
  Expires a promotion and prevents future redemptions.
  """
  def expire_promotion(%Promotion{status: :active} = promo) do
    promo
    |> Promotion.changeset(%{status: :expired, expired_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def expire_promotion(%Promotion{}), do: {:error, :only_active_can_be_expired}


  @doc """
  Evaluates which active promotions apply to the given cart and returns
  a list of applicable CartDiscount structs.
  """
  def evaluate_cart(customer_id, cart) do
    now = DateTime.utc_now()

    active_promos =
      from(p in Promotion,
        where: p.status == :active and p.starts_at <= ^now and p.ends_at >= ^now
      )
      |> Repo.all()

    Enum.flat_map(active_promos, fn promo ->
      if promotion_applies?(promo, customer_id, cart) do
        [%CartDiscount{promotion: promo, amount_cents: compute_discount(promo, cart)}]
      else
        []
      end
    end)
  end

  defp promotion_applies?(%Promotion{min_cart_cents: min}, _customer_id, cart) do
    cart_total(cart) >= (min || 0)
  end

  defp cart_total(cart) do
    Enum.sum(Enum.map(cart.items, & &1.unit_price_cents * &1.quantity))
  end

  @doc """
  Returns a detailed breakdown of discount amounts for auditing or display.
  """
  def compute_discount_breakdown(promo, cart) do
    total = cart_total(cart)
    discount = compute_discount(promo, cart)

    %{
      promotion_id: promo.id,
      promotion_name: promo.name,
      cart_total_cents: total,
      discount_cents: discount,
      final_total_cents: total - discount
    }
  end

  defp compute_discount(%Promotion{discount_type: :percentage, discount_value: pct}, cart) do
    round(cart_total(cart) * pct / 100.0)
  end

  defp compute_discount(%Promotion{discount_type: :fixed, discount_value: amount}, _cart) do
    amount
  end

  defp compute_discount(%Promotion{discount_type: :bogo}, cart) do
    sorted = cart.items |> Enum.sort_by(& &1.unit_price_cents, :desc)
    case sorted do
      [cheapest | _] -> cheapest.unit_price_cents
      _ -> 0
    end
  end


  @doc """
  Records that a promotion was redeemed for a given order and customer.
  """
  def track_redemption(promo_id, customer_id, order_id) do
    %PromotionRedemption{}
    |> PromotionRedemption.changeset(%{
      promotion_id: promo_id,
      customer_id: customer_id,
      order_id: order_id,
      redeemed_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Returns the total redemption count for a promotion.
  """
  def redemption_count(promo_id) do
    Repo.one(from r in PromotionRedemption, where: r.promotion_id == ^promo_id, select: count(r.id))
  end

end
```
