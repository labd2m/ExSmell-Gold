# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `backfill_currency_codes/0`, `currency_for_country/1`
- **Affected functions:** `change/0`, `backfill_currency_codes/0`, `currency_for_country/1`
- **Short explanation:** This migration adds a `currency_code` column to `transactions` (structural change) and then joins with the `merchants` table to derive and store a currency code based on merchant country (data manipulation). Cross-table lookups and domain-rule-driven writes should not appear in an `Ecto.Migration` module.

---

```elixir
defmodule Payments.Repo.Migrations.AddCurrencyCodeToTransactions do
  use Ecto.Migration

  import Ecto.Query
  alias Payments.Repo

  @country_currency %{
    "US" => "USD", "GB" => "GBP", "DE" => "EUR",
    "FR" => "EUR", "JP" => "JPY", "CA" => "CAD",
    "AU" => "AUD", "BR" => "BRL", "IN" => "INR",
    "MX" => "MXN", "SG" => "SGD", "CH" => "CHF"
  }

  def change do
    alter table("transactions") do
      add :currency_code, :string, null: true, size: 3
    end

    create index("transactions", [:currency_code])
    create index("transactions", [:currency_code, :processed_at])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration joins transactions with
    # merchants to apply a country-to-currency mapping and updates the currency_code
    # column. This cross-table data derivation is a data manipulation concern and
    # should be placed in a dedicated Mix task rather than an Ecto.Migration.
    backfill_currency_codes()
    # VALIDATION: SMELL END
  end

  defp backfill_currency_codes do
    from(t in "transactions",
      join: m in "merchants", on: m.id == t.merchant_id,
      where: is_nil(t.currency_code),
      select: %{id: t.id, country: m.country_code}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, country: country} ->
      currency = currency_for_country(country)

      from(t in "transactions", where: t.id == ^id)
      |> Repo.update_all(set: [currency_code: currency])
    end)
  end

  defp currency_for_country(country) when is_binary(country) do
    Map.get(@country_currency, String.upcase(country), "USD")
  end

  defp currency_for_country(_), do: "USD"
end
```
