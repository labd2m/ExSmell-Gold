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

    populate_display_names()
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
