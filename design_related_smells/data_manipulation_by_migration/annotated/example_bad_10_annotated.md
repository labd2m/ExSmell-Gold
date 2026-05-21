# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `assign_tiers/0`, `resolve_tier/1`
- **Affected functions:** `change/0`, `assign_tiers/0`, `resolve_tier/1`
- **Short explanation:** This migration adds the `tier` column to `subscriptions` (structural change) and then queries the table to classify each subscription into a tier based on its `plan_code` (data manipulation). The data backfill should be extracted into a dedicated Mix task rather than embedded in the migration.

---

```elixir
defmodule Billing.Repo.Migrations.AddTierToSubscriptions do
  use Ecto.Migration

  import Ecto.Query
  alias Billing.Repo

  @tier_rules [
    {~r/^enterprise/i, "enterprise"},
    {~r/^(pro|professional)/i, "professional"},
    {~r/^(growth|scale)/i, "growth"},
    {~r/^(starter|basic|free)/i, "starter"}
  ]

  def change do
    alter table("subscriptions") do
      add :tier, :string, null: true, default: "starter"
    end

    create index("subscriptions", [:tier])
    create index("subscriptions", [:tier, :status])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration performs data manipulation
    # by reading existing subscription rows and updating their tier values based on
    # business logic. This couples schema migration with data transformation,
    # reducing testability and increasing deployment risk.
    assign_tiers()
    # VALIDATION: SMELL END
  end

  defp assign_tiers do
    from(s in "subscriptions",
      where: s.tier == "starter" or is_nil(s.tier),
      select: %{id: s.id, plan_code: s.plan_code}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, plan_code: plan_code} ->
      tier = resolve_tier(plan_code)

      from(s in "subscriptions", where: s.id == ^id)
      |> Repo.update_all(set: [tier: tier])
    end)
  end

  defp resolve_tier(plan_code) when is_binary(plan_code) do
    @tier_rules
    |> Enum.find_value("starter", fn {pattern, tier} ->
      if Regex.match?(pattern, plan_code), do: tier
    end)
  end

  defp resolve_tier(_), do: "starter"
end
```
