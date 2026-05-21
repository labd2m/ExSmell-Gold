# Code Smell Example 41

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_default_currency/0`
- **Short explanation:** The migration both alters the `accounts` table (structural change) and updates existing rows to set a default currency value (data manipulation), violating the single-responsibility principle for migrations.

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration performs structural changes
    # (adding columns) AND data manipulation (updating existing rows with a default
    # currency value), mixing two distinct responsibilities in one module.
    backfill_default_currency()
    # VALIDATION: SMELL END
  end

  defp backfill_default_currency do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in "accounts",
      where: is_nil(a.currency),
      update: [set: [currency: "USD", currency_updated_at: ^now]]
    )
    |> Repo.update_all([])
  end
end
```
