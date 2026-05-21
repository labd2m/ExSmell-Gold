# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `populate_full_names/0`, `build_full_name/2`
- **Short explanation:** The migration introduces a `full_name` column to the `contacts` table and then immediately iterates over all existing rows, concatenates `first_name` and `last_name`, and writes the result into the new column. Constructing and persisting derived data is a data manipulation concern that should be extracted to a separate Mix task.

---

```elixir
defmodule CRM.Repo.Migrations.AddFullNameToContacts do
  use Ecto.Migration

  import Ecto.Query
  alias CRM.Repo

  def change do
    alter table("contacts") do
      add :full_name,          :string,  null: true
      add :full_name_search,   :tsvector, null: true
    end

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because, after the structural alteration,
    # the migration reads every contact's first_name and last_name, constructs
    # a full_name string, and persists it back to the database. This data
    # backfill couples two distinct responsibilities in one module and makes
    # both harder to test independently.
    populate_full_names()
    # VALIDATION: SMELL END

    alter table("contacts") do
      modify :full_name, :string, null: false
    end

    create index("contacts", [:full_name])
  end

  defp populate_full_names do
    contacts =
      from(c in "contacts",
        select: %{id: c.id, first_name: c.first_name, last_name: c.last_name}
      )
      |> Repo.all()

    Enum.each(contacts, fn %{id: id, first_name: first, last_name: last} ->
      full = build_full_name(first, last)

      from(c in "contacts", where: c.id == ^id)
      |> Repo.update_all(set: [full_name: full])
    end)
  end

  defp build_full_name(nil, last),   do: String.trim(last || "")
  defp build_full_name(first, nil),  do: String.trim(first || "")
  defp build_full_name(first, last), do: "#{String.trim(first)} #{String.trim(last)}"
end
```
