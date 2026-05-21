```elixir
defmodule Billing.Repo.Migrations.AddCurrencyCodeToInvoices do
  use Ecto.Migration


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

end
```
