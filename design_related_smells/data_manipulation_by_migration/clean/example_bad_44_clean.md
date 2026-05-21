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

    seed_notification_preferences()
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
end```
