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

    assign_tiers()
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
