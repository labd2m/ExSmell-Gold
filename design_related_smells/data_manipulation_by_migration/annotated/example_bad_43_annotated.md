# Code Smell Example 43

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `populate_shipping_zone/0`
- **Short explanation:** The migration creates the `shipping_zone` column (structural change) and immediately after populates it by reading warehouse region data from the database (data manipulation), coupling schema evolution with a data-backfill operation in the same module.

```elixir
defmodule LogisticsApp.Repo.Migrations.AddShippingZoneToWarehouses do
  use Ecto.Migration

  import Ecto.Query
  alias LogisticsApp.Repo

  @region_zone_mapping %{
    "northeast" => "zone_a",
    "southeast" => "zone_b",
    "midwest"   => "zone_c",
    "southwest" => "zone_d",
    "west"      => "zone_e"
  }

  def change do
    alter table("warehouses") do
      add :shipping_zone, :string, null: true
      add :zone_last_updated, :utc_datetime, null: true
    end

    create index("warehouses", [:shipping_zone])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration mixes DDL (adding columns)
    # with DML (reading warehouse region values and writing shipping zone data back
    # into existing rows). Data backfill logic should live in a dedicated Mix task.
    populate_shipping_zone()
    # VALIDATION: SMELL END
  end

  defp populate_shipping_zone do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    warehouses = from(w in "warehouses", select: {w.id, w.region}) |> Repo.all()

    Enum.each(warehouses, fn {id, region} ->
      zone = Map.get(@region_zone_mapping, region, "zone_unknown")

      from(w in "warehouses",
        where: w.id == ^id,
        update: [set: [shipping_zone: ^zone, zone_last_updated: ^now]]
      )
      |> Repo.update_all([])
    end)
  end
end
```
