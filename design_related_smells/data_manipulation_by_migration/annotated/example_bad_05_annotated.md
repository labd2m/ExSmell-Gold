# Annotated Bad Example 05

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddPlanTierToSubscriptions`
- **Affected function(s):** `change/0`, `classify_existing_subscriptions/0`
- **Short explanation:** The migration adds a `plan_tier` column to `subscriptions` (schema change) and also reads existing subscription records to classify and write their tier based on the monthly price (data manipulation). These two concerns reduce cohesion and testability and should be separated.

---

## Code

```elixir
defmodule SaaS.Repo.Migrations.AddPlanTierToSubscriptions do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration both performs a structural change
  # (adding :plan_tier to subscriptions) and manipulates existing data rows
  # (classifying subscriptions by tier based on their monthly_price_cents). These
  # two concerns should be in separate modules to improve testability and cohesion.

  import Ecto.Query
  alias SaaS.Billing.Subscription
  alias SaaS.Repo

  @starter_ceiling_cents   4_999
  @growth_ceiling_cents   19_999
  @business_ceiling_cents 99_999

  def change do
    alter table("subscriptions") do
      add :plan_tier, :string, null: false, default: "starter"
      add :tier_assigned_at, :utc_datetime
    end

    create index("subscriptions", [:plan_tier])

    flush()

    classify_existing_subscriptions()
  end

  defp classify_existing_subscriptions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Subscription,
      where: s.status in ["active", "trialing"],
      select: %{id: s.id, monthly_price_cents: s.monthly_price_cents}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, monthly_price_cents: price} ->
      tier = determine_tier(price)

      from(s in Subscription, where: s.id == ^id)
      |> Repo.update_all(set: [plan_tier: tier, tier_assigned_at: now])
    end)
  end

  defp determine_tier(price) when price <= @starter_ceiling_cents,  do: "starter"
  defp determine_tier(price) when price <= @growth_ceiling_cents,   do: "growth"
  defp determine_tier(price) when price <= @business_ceiling_cents, do: "business"
  defp determine_tier(_),                                            do: "enterprise"

  # VALIDATION: SMELL END
end
```
