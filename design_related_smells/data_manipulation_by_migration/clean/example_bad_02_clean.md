```elixir
defmodule Accounts.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration


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

end
```
