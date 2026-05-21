```elixir
defmodule SaaS.Repo.Migrations.AddPlanTierToSubscriptions do
  use Ecto.Migration


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

end
```
