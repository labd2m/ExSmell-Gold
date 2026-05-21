# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `migrate_user_roles/0`
- **Short explanation:** After adding the `role` column to `users`, the migration performs a cross-table query against `user_permissions` to infer each user's role and writes the result back to the new column. Querying a related table, applying inference logic, and persisting derived values is data manipulation that should not appear inside `Ecto.Migration`.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after adding the role column the
    # migration joins users with user_permissions to derive each user's
    # effective role, then writes the inferred value back to the users table.
    # This cross-table lookup, role inference, and data write-back is a data
    # manipulation concern that should be separated into a dedicated Mix task
    # rather than embedded in Ecto.Migration.change/0.
    migrate_user_roles()
    # VALIDATION: SMELL END
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
