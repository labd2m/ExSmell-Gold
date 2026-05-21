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

    backfill_currency_codes()
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
