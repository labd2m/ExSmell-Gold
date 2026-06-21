# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_country_codes/0`
- **Short explanation:** After adding `country_code` and `country_name` columns to `shipping_addresses`, the migration queries each row's existing `country` free-text field, maps it to an ISO code, and writes the normalized values back. This normalization and backfill logic is data manipulation that should not appear inside `Ecto.Migration`.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration reads the free-text
    # `country` field from existing shipping_address rows, resolves each
    # value to an ISO 3166-1 alpha-2 code via a lookup table, and writes the
    # normalized country_code and country_name back to the database. This is
    # a data normalization and backfill step that should be extracted to a
    # separate Mix task instead of being placed inside Ecto.Migration.change/0.
    backfill_country_codes()
    # VALIDATION: SMELL END
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
