```elixir
defmodule Logistics.Repo.Migrations.AddCountryCodeToShippingAddresses do
  use Ecto.Migration

  import Ecto.Query
  alias Logistics.Repo

  @country_name_to_code %{
    "United States"  => "US",
    "United Kingdom" => "GB",
    "Canada"         => "CA",
    "Australia"      => "AU",
    "Germany"        => "DE",
    "France"         => "FR",
    "Brazil"         => "BR",
    "India"          => "IN",
    "Japan"          => "JP",
    "Mexico"         => "MX"
  }

  def change do
    alter table("shipping_addresses") do
      add :country_code,     :string, size: 2,  null: true
      add :country_name,     :string, size: 100, null: true
      add :country_verified, :boolean, default: false, null: false
    end

    create index("shipping_addresses", [:country_code])

    flush()

    backfill_country_codes()
  end

  defp backfill_country_codes do
    rows =
      from(a in "shipping_addresses",
        where: not is_nil(a.country),
        select: %{id: a.id, country: a.country}
      )
      |> Repo.all()

    Enum.each(rows, fn %{id: id, country: country} ->
      trimmed = String.trim(country)

      case Map.get(@country_name_to_code, trimmed) do
        nil ->
          :ok

        code ->
          from(a in "shipping_addresses", where: a.id == ^id)
          |> Repo.update_all(
            set: [country_code: code, country_name: trimmed, country_verified: true]
          )
      end
    end)
  end
end
```
