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

    backfill_verified_at()
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
