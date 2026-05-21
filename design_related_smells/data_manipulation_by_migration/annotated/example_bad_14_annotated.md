# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `backfill_verified_at/0`
- **Affected functions:** `change/0`, `backfill_verified_at/0`
- **Short explanation:** This migration adds the `verified_at` timestamp column to `users` (structural change) and then updates existing rows, inferring a verification timestamp from related `verification_tokens` records (data manipulation). Querying related tables and making business-rule-driven updates inside a migration is exactly the kind of mixed responsibility this smell describes.

---

```elixir
defmodule Auth.Repo.Migrations.AddVerifiedAtToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Auth.Repo

  def change do
    alter table("users") do
      add :verified_at, :utc_datetime, null: true
    end

    create index("users", [:verified_at])

    alter table("verification_tokens") do
      add :consumed, :boolean, default: false, null: false
    end

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads data from two tables
    # (users and verification_tokens) and writes back a derived timestamp to users.
    # This is a data transformation step that should live in a Mix task,
    # not inside an Ecto.Migration module alongside schema changes.
    backfill_verified_at()
    # VALIDATION: SMELL END
  end

  defp backfill_verified_at do
    verified_user_ids_and_times =
      from(t in "verification_tokens",
        where: t.verified == true,
        group_by: t.user_id,
        select: {t.user_id, min(t.verified_at)}
      )
      |> Repo.all()

    Enum.each(verified_user_ids_and_times, fn {user_id, verified_at} ->
      from(u in "users",
        where: u.id == ^user_id and is_nil(u.verified_at)
      )
      |> Repo.update_all(set: [verified_at: verified_at])
    end)
  end
end
```
