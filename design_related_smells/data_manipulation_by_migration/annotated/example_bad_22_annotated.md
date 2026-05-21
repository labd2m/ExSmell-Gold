# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `backfill_last_login/0`
- **Affected functions:** `change/0`, `backfill_last_login/0`
- **Short explanation:** This migration adds a `last_login_at` column to `users` (structural change) and then queries the `user_sessions` audit table to find and write the most recent login time per user (data manipulation). Mining historical session data to backfill a derived column on a separate table is a data transformation task that belongs in a Mix task, not in a migration.

---

```elixir
defmodule Auth.Repo.Migrations.AddLastLoginAtToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Auth.Repo

  def change do
    alter table("users") do
      add :last_login_at,      :utc_datetime, null: true
      add :login_count,        :integer, default: 0, null: false
      add :last_login_ip,      :string, null: true, size: 45
    end

    create index("users", [:last_login_at])
    create index("users", [:login_count])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration mines the user_sessions table
    # (which acts as an audit log) to compute and write last_login_at, login_count,
    # and last_login_ip per user. This is data transformation logic that should be
    # separated into a Mix task rather than embedded in an Ecto.Migration.
    backfill_last_login()
    # VALIDATION: SMELL END
  end

  defp backfill_last_login do
    user_stats =
      from(s in "user_sessions",
        where: s.event_type == "login" and s.success == true,
        group_by: s.user_id,
        select: %{
          user_id:     s.user_id,
          last_login:  max(s.inserted_at),
          login_count: count(s.id)
        }
      )
      |> Repo.all()

    Enum.each(user_stats, fn %{user_id: uid, last_login: ts, login_count: cnt} ->
      last_ip =
        from(s in "user_sessions",
          where:
            s.user_id == ^uid and
            s.event_type == "login" and
            s.success == true and
            s.inserted_at == ^ts,
          select: s.ip_address,
          limit: 1
        )
        |> Repo.one()

      from(u in "users", where: u.id == ^uid)
      |> Repo.update_all(
        set: [
          last_login_at:  ts,
          login_count:    cnt,
          last_login_ip:  last_ip
        ]
      )
    end)
  end
end
```
