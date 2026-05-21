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

    backfill_expiry_dates()
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
