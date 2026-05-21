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

    populate_shipping_zone()
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
end```
