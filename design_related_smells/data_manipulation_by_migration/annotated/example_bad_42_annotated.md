# Code Smell Example 42

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `assign_default_roles/0`
- **Short explanation:** The migration adds a `role` column to the `users` table (structural change) and then queries existing users to assign them a default role based on their `inserted_at` date (data manipulation), mixing schema evolution with business logic applied to live data.

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after the structural DDL changes the
    # migration continues to manipulate existing row data — assigning roles based
    # on insertion date — which is data-layer business logic that belongs in a
    # separate Mix task, not inside an Ecto.Migration module.
    assign_default_roles()
    # VALIDATION: SMELL END
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
end
```
