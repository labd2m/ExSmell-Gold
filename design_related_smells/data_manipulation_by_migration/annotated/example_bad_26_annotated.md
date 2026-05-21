# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `assign_subscription_tiers/0`
- **Short explanation:** After adding the `subscription_tier` column, the migration queries the `accounts` table and derives each account's tier from its `plan_name` field, then writes the result back. This is data manipulation logic (deriving and backfilling values) that should live in a dedicated Mix task, not inside a migration.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration reads existing account
    # rows, derives their subscription tier from another column, and persists
    # that derived value — all inside Ecto.Migration.change/0. Schema
    # migrations should only alter structure; data transformations of this
    # kind reduce cohesion and complicate rollback/testing.
    assign_subscription_tiers()
    # VALIDATION: SMELL END
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
