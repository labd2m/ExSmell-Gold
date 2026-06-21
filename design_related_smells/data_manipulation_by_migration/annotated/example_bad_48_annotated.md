# Code Smell Example 48

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `split_full_name_into_parts/0`
- **Short explanation:** The migration adds `first_name` and `last_name` columns to `employees` (structural change) and then reads each existing `full_name` value, splits it on whitespace, and writes the parts into the new columns (data manipulation), blending schema changes with string-parsing application logic.

```elixir
defmodule HrSystem.Repo.Migrations.AddNamePartsToEmployees do
  use Ecto.Migration

  import Ecto.Query
  alias HrSystem.Repo

  def change do
    alter table("employees") do
      add :first_name,       :string, null: true
      add :last_name,        :string, null: true
      add :name_split_at,    :utc_datetime, null: true
    end

    create index("employees", [:last_name])
    create index("employees", [:first_name, :last_name])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration adds new columns (DDL)
    # and then reads every employee's full_name, applies string-splitting logic,
    # and persists the derived values (DML). Parsing and transforming existing
    # data belongs in a dedicated Mix task, not inside an Ecto.Migration module.
    split_full_name_into_parts()
    # VALIDATION: SMELL END
  end

  defp split_full_name_into_parts do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in "employees",
      where: not is_nil(e.full_name),
      select: {e.id, e.full_name}
    )
    |> Repo.all()
    |> Enum.each(fn {id, full_name} ->
      {first, last} = parse_name(full_name)

      from(e in "employees",
        where: e.id == ^id,
        update: [
          set: [
            first_name:    ^first,
            last_name:     ^last,
            name_split_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])
    end)
  end

  defp parse_name(full_name) do
    parts = String.split(full_name, " ", trim: true)

    case parts do
      []          -> {"", ""}
      [only]      -> {only, ""}
      [f | rest]  -> {f, Enum.join(rest, " ")}
    end
  end
end
```
