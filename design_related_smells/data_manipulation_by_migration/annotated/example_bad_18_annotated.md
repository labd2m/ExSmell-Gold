# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `sync_notification_counts/0`
- **Affected functions:** `change/0`, `sync_notification_counts/0`
- **Short explanation:** This migration adds the `unread_notification_count` column to `users` (structural change) and then aggregates data from the `notifications` table per user to populate it (data manipulation). Aggregating from related tables and writing denormalized counts back to the parent table during a migration is a textbook example of this smell.

---

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

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration aggregates notification
    # records per user from a separate table and writes the computed count back
    # to users. Aggregating and denormalizing data from related tables is data
    # manipulation and should be extracted into a separate Mix task.
    sync_notification_counts()
    # VALIDATION: SMELL END
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
