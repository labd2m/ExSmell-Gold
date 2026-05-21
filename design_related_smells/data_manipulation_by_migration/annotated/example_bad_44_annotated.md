# Code Smell Example 44

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `seed_notification_preferences/0`
- **Short explanation:** The migration creates the `notification_preferences` table (structural change) and then inserts one row per existing user into the new table (data manipulation), coupling schema creation with a data-seeding operation that belongs in a separate Mix task.

```elixir
defmodule NotificationsApp.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  import Ecto.Query
  alias NotificationsApp.Repo

  def change do
    create table("notification_preferences") do
      add :user_id,       references("users", on_delete: :delete_all), null: false
      add :email_enabled, :boolean, default: true,  null: false
      add :sms_enabled,   :boolean, default: false, null: false
      add :push_enabled,  :boolean, default: true,  null: false
      add :digest_freq,   :string,  default: "daily", null: false

      timestamps()
    end

    create unique_index("notification_preferences", [:user_id])
    create index("notification_preferences", [:digest_freq])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because, after creating the table structure, the
    # migration fetches all existing user IDs and inserts default preference rows
    # for them — a data-seeding operation that makes the migration less cohesive,
    # harder to test, and fragile when run against production data.
    seed_notification_preferences()
    # VALIDATION: SMELL END
  end

  defp seed_notification_preferences do
    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_naive()

    user_ids =
      from(u in "users", select: u.id)
      |> Repo.all()

    entries =
      Enum.map(user_ids, fn uid ->
        %{
          user_id:       uid,
          email_enabled: true,
          sms_enabled:   false,
          push_enabled:  true,
          digest_freq:   "daily",
          inserted_at:   now,
          updated_at:    now
        }
      end)

    Repo.insert_all("notification_preferences", entries, on_conflict: :nothing)
  end
end
```
