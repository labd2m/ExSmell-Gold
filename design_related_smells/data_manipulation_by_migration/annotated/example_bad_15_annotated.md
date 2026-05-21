# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `populate_display_names/0`, `build_display_name/2`
- **Affected functions:** `change/0`, `populate_display_names/0`, `build_display_name/2`
- **Short explanation:** This migration adds a `display_name` column to `user_profiles` (structural change) and immediately reads every profile row to concatenate `first_name` and `last_name` into the new column (data manipulation). Generating derived data from existing fields in a migration violates single responsibility and makes the migration difficult to safely revert or test independently.

---

```elixir
defmodule UserManagement.Repo.Migrations.AddDisplayNameToUserProfiles do
  use Ecto.Migration

  import Ecto.Query
  alias UserManagement.Repo

  def change do
    alter table("user_profiles") do
      add :display_name, :string, null: true, size: 255
    end

    create index("user_profiles", [:display_name])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads all user_profile rows
    # and constructs a display_name from first_name and last_name — a data
    # manipulation task. The migration module should only handle schema changes;
    # data derivation should be in a separate Mix task to allow proper testing.
    populate_display_names()
    # VALIDATION: SMELL END
  end

  defp populate_display_names do
    from(p in "user_profiles",
      where: is_nil(p.display_name),
      select: %{id: p.id, first_name: p.first_name, last_name: p.last_name}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, first_name: first, last_name: last} ->
      display = build_display_name(first, last)

      from(p in "user_profiles", where: p.id == ^id)
      |> Repo.update_all(set: [display_name: display])
    end)
  end

  defp build_display_name(first, last)
       when is_binary(first) and is_binary(last) do
    first_trimmed = String.trim(first)
    last_trimmed  = String.trim(last)

    case {first_trimmed, last_trimmed} do
      {"", ""}    -> "Anonymous User"
      {f, ""}     -> f
      {"", l}     -> l
      {f, l}      -> "#{f} #{l}"
    end
  end

  defp build_display_name(first, _last) when is_binary(first) do
    case String.trim(first) do
      "" -> "Anonymous User"
      f  -> f
    end
  end

  defp build_display_name(_, _), do: "Anonymous User"
end
```
