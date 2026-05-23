# Example Bad 18 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_earned_points/2`, `get_redemption_rate/1`, `get_birthday_bonus_points/1`, and `get_tier_benefits/1` inside `Retail.LoyaltyManager`
- **Affected Functions**: `calculate_earned_points/2`, `get_redemption_rate/1`, `get_birthday_bonus_points/1`, `get_tier_benefits/1`
- **Explanation**: The loyalty tier logic (`:bronze`, `:silver`, `:gold`) is spread across four functions. Adding a new tier (e.g., `:platinum`) forces four independent changes in scattered locations across the module, embodying Shotgun Surgery.

```elixir
defmodule Retail.LoyaltyManager do
  @moduledoc """
  Manages the retail loyalty program including points earning,
  redemption rates, birthday bonuses, and tier benefit entitlements
  for Bronze, Silver, and Gold loyalty members.
  """

  alias Retail.{LoyaltyAccount, PointsLedger, RedemptionEngine, MemberPortal, CampaignService}

  def record_purchase(%LoyaltyAccount{} = account, purchase_amount, transaction_id) do
    points = calculate_earned_points(purchase_amount, account.tier)

    with {:ok, _entry} <- PointsLedger.credit(account.id, points, transaction_id),
         {:ok, updated} <- update_points_balance(account, points) do
      maybe_trigger_tier_upgrade(updated)
      MemberPortal.send_points_earned(account.member_id, points, updated.points_balance)
      {:ok, updated}
    end
  end

  defp update_points_balance(account, earned_points) do
    updated = %{account | points_balance: account.points_balance + earned_points}
    LoyaltyAccount.update(updated)
  end

  def redeem_points(%LoyaltyAccount{} = account, points_to_redeem) do
    rate = get_redemption_rate(account.tier)

    cond do
      points_to_redeem > account.points_balance ->
        {:error, :insufficient_points}

      points_to_redeem < 100 ->
        {:error, :minimum_redemption_not_met}

      true ->
        cash_value = Float.round(points_to_redeem * rate, 2)
        updated = %{account | points_balance: account.points_balance - points_to_redeem}

        with {:ok, saved}    <- LoyaltyAccount.update(updated),
             {:ok, voucher}  <- RedemptionEngine.issue_voucher(account.member_id, cash_value) do
          PointsLedger.debit(account.id, points_to_redeem, :redemption)
          {:ok, voucher}
        end
    end
  end

  def apply_birthday_bonus(%LoyaltyAccount{} = account) do
    today = Date.utc_today()

    if account.birthday_month == today.month and not account.birthday_bonus_applied? do
      bonus = get_birthday_bonus_points(account.tier)

      with {:ok, updated} <- update_points_balance(account, bonus) do
        LoyaltyAccount.update(%{updated | birthday_bonus_applied?: true})
        MemberPortal.send_birthday_message(account.member_id, bonus)
        {:ok, updated}
      end
    else
      {:error, :birthday_bonus_not_applicable}
    end
  end

  defp maybe_trigger_tier_upgrade(%LoyaltyAccount{} = account) do
    new_tier = determine_tier(account.annual_spend)

    if new_tier != account.tier do
      updated = %{account | tier: new_tier, tier_changed_at: Date.utc_today()}
      LoyaltyAccount.update(updated)
      CampaignService.send_tier_upgrade_offer(account.member_id, new_tier, get_tier_benefits(new_tier))
    end
  end

  defp determine_tier(annual_spend) when annual_spend >= 5_000, do: :gold
  defp determine_tier(annual_spend) when annual_spend >= 1_000, do: :silver
  defp determine_tier(_), do: :bronze

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new loyalty tier (e.g., :platinum)
  # requires a new clause here AND in get_redemption_rate/1, get_birthday_bonus_points/1,
  # and get_tier_benefits/1 — four scattered changes for one new tier.
  def calculate_earned_points(amount, :bronze), do: trunc(amount * 1.0)
  def calculate_earned_points(amount, :silver), do: trunc(amount * 1.5)
  def calculate_earned_points(amount, :gold),   do: trunc(amount * 2.0)
  def calculate_earned_points(amount, _),       do: trunc(amount * 0.5)
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new tier also requires a new redemption rate
  # clause here, independent of calculate_earned_points/2.
  def get_redemption_rate(:bronze), do: 0.005
  def get_redemption_rate(:silver), do: 0.008
  def get_redemption_rate(:gold),   do: 0.012
  def get_redemption_rate(_),       do: 0.003
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new tier also requires a birthday bonus
  # clause here, independent of the previous two locations.
  def get_birthday_bonus_points(:bronze), do: 100
  def get_birthday_bonus_points(:silver), do: 300
  def get_birthday_bonus_points(:gold),   do: 750
  def get_birthday_bonus_points(_),       do: 50
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new tier also requires a benefits clause here,
  # completing the four-location change for every new loyalty tier.
  def get_tier_benefits(:bronze) do
    %{free_shipping_threshold: 75.00, exclusive_sales: false, personal_shopper: false}
  end

  def get_tier_benefits(:silver) do
    %{free_shipping_threshold: 40.00, exclusive_sales: true, personal_shopper: false}
  end

  def get_tier_benefits(:gold) do
    %{free_shipping_threshold: 0.00, exclusive_sales: true, personal_shopper: true}
  end

  def get_tier_benefits(_) do
    %{free_shipping_threshold: 100.00, exclusive_sales: false, personal_shopper: false}
  end
  # VALIDATION: SMELL END [location 4 of 4]

  def get_member_summary(%LoyaltyAccount{} = account) do
    %{
      tier:             account.tier,
      points_balance:   account.points_balance,
      redemption_rate:  get_redemption_rate(account.tier),
      cash_equivalent:  Float.round(account.points_balance * get_redemption_rate(account.tier), 2),
      tier_benefits:    get_tier_benefits(account.tier)
    }
  end

  def list_tiers, do: [:bronze, :silver, :gold]
end
```
