# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `assign_regions/0`, `region_for_state/1`
- **Affected functions:** `change/0`, `assign_regions/0`, `region_for_state/1`
- **Short explanation:** The migration adds a `region` column to `warehouses` (structural change) and then reads existing rows to derive a US geographic region from the state code field (data manipulation). Embedding business-rule-based data backfilling inside a migration couples schema and domain logic in ways that are hard to test and roll back safely.

---

```elixir
defmodule Logistics.Repo.Migrations.AddRegionToWarehouses do
  use Ecto.Migration

  import Ecto.Query
  alias Logistics.Repo

  @northeast ~w(CT ME MA NH NJ NY PA RI VT)
  @southeast ~w(AL AR FL GA KY LA MS NC SC TN VA WV)
  @midwest   ~w(IL IN IA KS MI MN MO NE ND OH SD WI)
  @southwest ~w(AZ NM OK TX)
  @west      ~w(AK CA CO HI ID MT NV OR UT WA WY)

  def change do
    alter table("warehouses") do
      add :region, :string, null: true
    end

    create index("warehouses", [:region])
    create index("warehouses", [:region, :active])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads existing warehouse rows
    # and applies business logic (US state-to-region mapping) to update the new
    # region column. This data manipulation responsibility should be separated into
    # a dedicated Mix task to keep the migration focused on schema changes only.
    assign_regions()
    # VALIDATION: SMELL END
  end

  defp assign_regions do
    from(w in "warehouses",
      where: is_nil(w.region),
      select: %{id: w.id, state_code: w.state_code}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, state_code: state_code} ->
      region = region_for_state(state_code)

      from(w in "warehouses", where: w.id == ^id)
      |> Repo.update_all(set: [region: region])
    end)
  end

  defp region_for_state(state) when is_binary(state) do
    upcased = String.upcase(state)

    cond do
      upcased in @northeast -> "northeast"
      upcased in @southeast -> "southeast"
      upcased in @midwest   -> "midwest"
      upcased in @southwest -> "southwest"
      upcased in @west      -> "west"
      true                  -> "other"
    end
  end

  defp region_for_state(_), do: "other"
end
```
