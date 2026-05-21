```elixir
defmodule BillingApp.Repo.Migrations.AddCurrencyToAccounts do
  use Ecto.Migration

  import Ecto.Query
  alias BillingApp.Repo

  def change do
    alter table("accounts") do
      add :currency, :string, null: true
      add :currency_updated_at, :utc_datetime, null: true
    end

    create index("accounts", [:currency])

    backfill_default_currency()
  end

  defp backfill_default_currency do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in "accounts",
      where: is_nil(a.currency),
      update: [set: [currency: "USD", currency_updated_at: ^now]]
    )
    |> Repo.update_all([])
  end
end```
