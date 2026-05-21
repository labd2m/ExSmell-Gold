```elixir
defmodule Notifications.Repo.Migrations.AddUnreadCountToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Notifications.Repo

  def change do
    alter table("users") do
      add :unread_notification_count, :integer, default: 0, null: false
    end

    create index("users", [:unread_notification_count])

    flush()

    sync_notification_counts()
  end

  defp sync_notification_counts do
    counts_by_user =
      from(n in "notifications",
        where: n.read == false and not is_nil(n.user_id),
        group_by: n.user_id,
        select: {n.user_id, count(n.id)}
      )
      |> Repo.all()

    Enum.each(counts_by_user, fn {user_id, count} ->
      from(u in "users", where: u.id == ^user_id)
      |> Repo.update_all(set: [unread_notification_count: count])
    end)
  end
end
```
