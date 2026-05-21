# Annotated Bad Example 03

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddCurrencyCodeToInvoices`
- **Affected function(s):** `change/0`, `populate_currency_codes/0`
- **Short explanation:** The migration both adds a `currency_code` column to the `invoices` table (structural change) and queries existing invoices to populate the new column based on associated billing account country data (data manipulation). These responsibilities must be separated.

---

## Code

```elixir
defmodule Billing.Repo.Migrations.AddCurrencyCodeToInvoices do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration module combines a structural DDL
  # change (adding :currency_code to invoices) with DML operations (reading billing
  # accounts to infer currency and updating invoice rows). This mixture of concerns
  # makes the migration harder to test and reason about.

  import Ecto.Query
  alias Billing.Invoices.Invoice
  alias Billing.Accounts.BillingAccount
  alias Billing.Repo

  @country_currency_map %{
    "US" => "USD",
    "GB" => "GBP",
    "DE" => "EUR",
    "FR" => "EUR",
    "JP" => "JPY",
    "BR" => "BRL",
    "CA" => "CAD"
  }

  @default_currency "USD"

  def change do
    alter table("invoices") do
      add :currency_code, :string, size: 3, null: false, default: @default_currency
      add :exchange_rate, :decimal, precision: 18, scale: 6
    end

    create index("invoices", [:currency_code])

    flush()

    populate_currency_codes()
  end

  defp populate_currency_codes do
    invoices_with_country =
      from(i in Invoice,
        join: ba in BillingAccount,
        on: ba.id == i.billing_account_id,
        select: %{invoice_id: i.id, country: ba.country_code}
      )
      |> Repo.all()

    Enum.each(invoices_with_country, fn %{invoice_id: id, country: country} ->
      currency = Map.get(@country_currency_map, country, @default_currency)

      from(i in Invoice, where: i.id == ^id)
      |> Repo.update_all(set: [currency_code: currency])
    end)
  end

  # VALIDATION: SMELL END
end
```
