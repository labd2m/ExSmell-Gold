# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `RewardsEngine.redeem/3` function
- **Affected function(s):** `RewardsEngine.redeem/3`
- **Short explanation:** `RewardsEngine.redeem/3` fetches a `MemberProfile` struct and a `RewardTier` struct and directly reads their internal fields (`.points_balance`, `.lifetime_points`, `.expiry_date`, `.redemption_multiplier`, `.min_redeem_points`, `.eligible_categories`) to process the redemption. These are internal constraints of `MemberProfile` and `RewardTier` that should be surfaced through their own dedicated API functions rather than being accessed as raw struct fields.

---

```elixir
defmodule MyApp.Loyalty.RewardsEngine do
  @moduledoc """
  Processes points redemption for loyalty program members.
  Validates member eligibility, tier rules, and category restrictions.
  """

  alias MyApp.Loyalty.{MemberProfile, RewardTier, RedemptionRecord}
  alias MyApp.Catalog.Product
  alias MyApp.Notifications.LoyaltyMailer

  @points_per_currency_unit 100

  def redeem(member_id, product_id, points_to_redeem) do
    with {:ok, member}  <- MemberProfile.fetch(member_id),
         {:ok, product} <- Product.fetch(product_id),
         {:ok, tier}    <- RewardTier.for_member(member_id) do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because redeem/3 directly reads .points_balance,
      # .lifetime_points, and .expiry_date from the MemberProfile struct, and
      # .redemption_multiplier, .min_redeem_points, and .eligible_categories from the
      # RewardTier struct. These internal fields should not be read directly here;
      # MemberProfile should expose redeemable_balance/1 and expiry_status/1, and
      # RewardTier should expose eligible_for?/2 and effective_discount/2.
      points_balance      = member.points_balance
      lifetime_points     = member.lifetime_points
      expiry_date         = member.expiry_date

      multiplier          = tier.redemption_multiplier
      min_points          = tier.min_redeem_points
      eligible_categories = tier.eligible_categories
      # VALIDATION: SMELL END

      today = Date.utc_today()

      cond do
        Date.compare(today, expiry_date) == :gt ->
          {:error, :membership_expired}

        points_to_redeem < min_points ->
          {:error, {:below_minimum, min_points}}

        points_to_redeem > points_balance ->
          {:error, :insufficient_points}

        eligible_categories != :all and product.category not in eligible_categories ->
          {:error, :category_not_eligible}

        true ->
          discount_value = (points_to_redeem / @points_per_currency_unit) * multiplier
          discount_value = min(discount_value, product.price)

          record = %{
            id:               generate_id(),
            member_id:        member_id,
            product_id:       product_id,
            points_redeemed:  points_to_redeem,
            discount_applied: Float.round(discount_value, 2),
            tier_id:          tier.id,
            redeemed_at:      DateTime.utc_now()
          }

          case RedemptionRecord.save(record) do
            {:ok, saved} ->
              new_balance = points_balance - points_to_redeem
              MemberProfile.update_points(member_id, new_balance)
              LoyaltyMailer.deliver_confirmation(member, saved)
              {:ok, saved}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  def accrue(member_id, purchase_amount) do
    case MemberProfile.fetch(member_id) do
      {:ok, member} ->
        {:ok, tier} = RewardTier.for_member(member_id)
        points  = floor(purchase_amount * @points_per_currency_unit * tier.accrual_rate)
        new_bal = member.points_balance + points
        MemberProfile.update_points(member_id, new_bal)
        {:ok, %{points_accrued: points, new_balance: new_bal}}

      error ->
        error
    end
  end

  def balance(member_id) do
    case MemberProfile.fetch(member_id) do
      {:ok, member} -> {:ok, member.points_balance}
      error         -> error
    end
  end

  def history(member_id, limit \\ 20) do
    :ets.tab2list(:redemption_records)
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(&1.member_id == member_id))
    |> Enum.sort_by(& &1.redeemed_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # --- Private helpers ---

  defp generate_id do
    "RDM-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
