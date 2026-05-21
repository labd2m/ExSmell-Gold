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

    assign_regions()
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
