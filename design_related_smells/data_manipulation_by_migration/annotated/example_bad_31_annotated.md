# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `backfill_expiry_dates/0`
- **Short explanation:** The migration adds `expires_at` and `is_expired` columns to the `user_sessions` table and then reads every existing session row, computes an expiry date from `created_at`, and writes it back. Computing and persisting derived temporal values for existing rows is data manipulation that does not belong inside a migration.

---

```elixir
defmodule Auth.Repo.Migrations.AddExpiresAtToUserSessions do
  use Ecto.Migration

  import Ecto.Query
  alias Auth.Repo

  @default_session_duration_seconds 86_400 * 30

  def change do
    alter table("user_sessions") do
      add :expires_at,  :utc_datetime, null: true
      add :is_expired,  :boolean, default: false, null: false
      add :expiry_type, :string, default: "rolling", null: false
    end

    create index("user_sessions", [:expires_at])
    create index("user_sessions", [:is_expired])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration reads all existing
    # session rows and computes an expires_at timestamp by adding a fixed
    # duration to each row's created_at value, then persists this back to
    # the database. Calculating and writing derived field values for existing
    # rows is data manipulation logic that should live in a separate Mix task,
    # not inside Ecto.Migration.change/0.
    backfill_expiry_dates()
    # VALIDATION: SMELL END
  end

  defp backfill_expiry_dates do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    sessions =
      from(s in "user_sessions",
        where: is_nil(s.expires_at),
        select: %{id: s.id, created_at: s.inserted_at}
      )
      |> Repo.all()

    Enum.each(sessions, fn %{id: id, created_at: created_at} ->
      expires_at =
        created_at
        |> DateTime.add(@default_session_duration_seconds, :second)
        |> DateTime.truncate(:second)

      is_expired = DateTime.compare(expires_at, now) == :lt

      from(s in "user_sessions", where: s.id == ^id)
      |> Repo.update_all(set: [expires_at: expires_at, is_expired: is_expired])
    end)
  end
end
```
