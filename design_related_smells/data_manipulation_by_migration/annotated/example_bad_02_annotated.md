# Annotated Bad Example 02

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddRoleToUsers`
- **Affected function(s):** `change/0`, `assign_default_roles/0`
- **Short explanation:** The migration adds a `role` column to the `users` table (structural change) and also queries existing users and updates their `role` based on their email domain (data manipulation). These two concerns should be separated into a migration and a dedicated Mix task.

---

## Code

```elixir
defmodule Accounts.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration simultaneously performs a structural
  # change (adding the :role column to the users table) and manipulates existing user data
  # (assigning roles based on email domain heuristics). Data backfill should not live
  # inside an Ecto.Migration module.

  import Ecto.Query
  alias Accounts.Auth.User
  alias Accounts.Repo

  @admin_domain "internal.myapp.com"
  @moderator_domain "partner.myapp.com"

  def change do
    alter table("users") do
      add :role, :string, null: false, default: "member"
      add :role_assigned_at, :utc_datetime
    end

    create index("users", [:role])

    flush()

    assign_default_roles()
  end

  defp assign_default_roles do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    users =
      from(u in User,
        select: %{id: u.id, email: u.email}
      )
      |> Repo.all()

    Enum.each(users, fn %{id: id, email: email} ->
      role = determine_role(email)

      from(u in User, where: u.id == ^id)
      |> Repo.update_all(set: [role: role, role_assigned_at: now])
    end)
  end

  defp determine_role(email) do
    cond do
      String.ends_with?(email, "@#{@admin_domain}")     -> "admin"
      String.ends_with?(email, "@#{@moderator_domain}") -> "moderator"
      true                                               -> "member"
    end
  end

  # VALIDATION: SMELL END
end
```
