```elixir
defmodule Identity.Repo.Migrations.AddDisplayNameToUserProfiles do
  use Ecto.Migration

  import Ecto.Query
  alias Identity.Repo

  def change do
    alter table("user_profiles") do
      add :display_name,           :string, null: true
      add :display_name_source,    :string, default: "username", null: false
      add :display_name_updated_at, :utc_datetime, null: true
    end

    create index("user_profiles", [:display_name])

    flush()

    populate_display_names()

    alter table("user_profiles") do
      modify :display_name, :string, null: false
    end
  end

  defp populate_display_names do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      from(p in "user_profiles",
        select: %{id: p.id, username: p.username}
      )
      |> Repo.all()

    Enum.each(rows, fn %{id: id, username: username} ->
      display_name = format_display_name(username)

      from(p in "user_profiles", where: p.id == ^id)
      |> Repo.update_all(
        set: [display_name: display_name, display_name_updated_at: now]
      )
    end)
  end

  defp format_display_name(username) when is_binary(username) do
    username
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_display_name(_), do: "User"
end
```
