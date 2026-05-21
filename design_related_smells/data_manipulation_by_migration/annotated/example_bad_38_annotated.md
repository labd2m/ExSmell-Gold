# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_verification_status/0`
- **Short explanation:** The migration adds `is_verified` and `verified_at` columns to `users`, then applies a business rule — marking users who confirmed their email and have been active for more than 30 days as verified — by updating existing rows. Applying business rules to existing data is a data manipulation concern that should not live in an `Ecto.Migration` module.

---

```elixir
defmodule Accounts.Repo.Migrations.AddIsVerifiedToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Accounts.Repo

  @days_active_threshold 30

  def change do
    alter table("users") do
      add :is_verified,         :boolean, default: false, null: false
      add :verified_at,         :utc_datetime, null: true
      add :verification_source, :string, default: "auto", null: false
    end

    create index("users", [:is_verified])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after adding the new columns the
    # migration evaluates a multi-condition business rule (email confirmed +
    # account age > 30 days) against every existing user row and updates
    # is_verified and verified_at accordingly. Applying business-rule-driven
    # data updates to existing rows is a data manipulation concern that should
    # be placed in a dedicated Mix task rather than inside Ecto.Migration.
    backfill_verification_status()
    # VALIDATION: SMELL END
  end

  defp backfill_verification_status do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@days_active_threshold * 86_400, :second)
      |> DateTime.truncate(:second)

    candidates =
      from(u in "users",
        where: u.email_confirmed == true and u.inserted_at <= ^cutoff,
        select: %{id: u.id, inserted_at: u.inserted_at}
      )
      |> Repo.all()

    Enum.each(candidates, fn %{id: id, inserted_at: inserted_at} ->
      verified_at = DateTime.truncate(inserted_at, :second)

      from(u in "users", where: u.id == ^id)
      |> Repo.update_all(
        set: [is_verified: true, verified_at: verified_at, verification_source: "migration"]
      )
    end)
  end
end
```
