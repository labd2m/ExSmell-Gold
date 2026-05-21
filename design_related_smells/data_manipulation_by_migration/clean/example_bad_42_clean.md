```elixir
defmodule AuthService.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias AuthService.Repo

  @legacy_cutoff ~D[2022-01-01]

  def change do
    alter table("users") do
      add :role, :string, null: false, default: "member"
      add :role_assigned_at, :utc_datetime, null: true
    end

    create index("users", [:role])
    create index("users", [:role, :inserted_at])

    flush()

    assign_default_roles()
  end

  defp assign_default_roles do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(u in "users",
      where: u.inserted_at < ^@legacy_cutoff,
      update: [set: [role: "legacy_member", role_assigned_at: ^now]]
    )
    |> Repo.update_all([])

    from(u in "users",
      where: u.inserted_at >= ^@legacy_cutoff,
      update: [set: [role: "member", role_assigned_at: ^now]]
    )
    |> Repo.update_all([])
  end
end```
