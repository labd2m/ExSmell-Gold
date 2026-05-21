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

    backfill_last_login()
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
