# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `populate_normalized_emails/0`
- **Affected functions:** `change/0`, `populate_normalized_emails/0`, `normalize_email/1`
- **Short explanation:** This migration adds a `normalized_email` column (structural change) and then iterates over all account rows to derive and store a lowercased, trimmed version of each email (data manipulation). Backfilling derived columns belongs in a Mix task, not in the migration module.

---

```elixir
defmodule Accounts.Repo.Migrations.AddNormalizedEmailToAccounts do
  use Ecto.Migration

  import Ecto.Query
  alias Accounts.Repo

  def change do
    alter table("accounts") do
      add :normalized_email, :string, null: true
    end

    create unique_index("accounts", [:normalized_email])

    alter table("accounts") do
      modify :email, :string, null: false
    end

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads every existing account
    # record and writes a computed normalized_email value, which is data manipulation.
    # Only schema-structural operations (add/remove/modify columns, create/drop indexes)
    # should appear in an Ecto.Migration module.
    populate_normalized_emails()
    # VALIDATION: SMELL END
  end

  defp populate_normalized_emails do
    from(a in "accounts",
      where: is_nil(a.normalized_email),
      select: %{id: a.id, email: a.email}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, email: email} ->
      normalized = normalize_email(email)

      from(a in "accounts", where: a.id == ^id)
      |> Repo.update_all(set: [normalized_email: normalized])
    end)
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil
end
```
