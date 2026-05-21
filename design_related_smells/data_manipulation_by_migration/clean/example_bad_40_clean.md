```elixir
defmodule Platform.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Platform.Repo

  def change do
    alter table("users") do
      add :role,            :string, default: "member", null: false
      add :role_granted_at, :utc_datetime, null: true
    end

    create index("users", [:role])

    flush()

    migrate_user_roles()
  end

  defp migrate_user_roles do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    admin_ids =
      from(p in "user_permissions",
        where: p.permission == "admin" and p.granted == true,
        select: p.user_id,
        distinct: true
      )
      |> Repo.all()

    moderator_ids =
      from(p in "user_permissions",
        where: p.permission == "moderate" and p.granted == true and p.user_id not in ^admin_ids,
        select: p.user_id,
        distinct: true
      )
      |> Repo.all()

    unless Enum.empty?(admin_ids) do
      from(u in "users", where: u.id in ^admin_ids)
      |> Repo.update_all(set: [role: "admin", role_granted_at: now])
    end

    unless Enum.empty?(moderator_ids) do
      from(u in "users", where: u.id in ^moderator_ids)
      |> Repo.update_all(set: [role: "moderator", role_granted_at: now])
    end
  end
end
```
