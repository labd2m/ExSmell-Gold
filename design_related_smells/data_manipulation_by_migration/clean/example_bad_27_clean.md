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

    populate_full_names()

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
