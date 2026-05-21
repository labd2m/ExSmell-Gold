```elixir
defmodule Billing.Repo.Migrations.AddSubscriptionTierToAccounts do
  use Ecto.Migration

  import Ecto.Query
  alias Billing.Repo

  @tier_map %{
    "starter"    => "basic",
    "growth"     => "standard",
    "business"   => "premium",
    "enterprise" => "enterprise"
  }

  def change do
    alter table("accounts") do
      add :subscription_tier, :string, null: true
      add :tier_assigned_at,  :utc_datetime, null: true
    end

    create index("accounts", [:subscription_tier])

    flush()

    assign_subscription_tiers()
  end

  defp assign_subscription_tiers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    accounts =
      from(a in "accounts",
        where: not is_nil(a.plan_name),
        select: %{id: a.id, plan_name: a.plan_name}
      )
      |> Repo.all()

    Enum.each(accounts, fn %{id: id, plan_name: plan_name} ->
      tier = Map.get(@tier_map, plan_name, "basic")

      from(a in "accounts", where: a.id == ^id)
      |> Repo.update_all(set: [subscription_tier: tier, tier_assigned_at: now])
    end)
  end
end
```
