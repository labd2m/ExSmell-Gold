```elixir
defmodule SubscriptionService.Repo.Migrations.AddArchivedToSubscriptions do
  use Ecto.Migration

  import Ecto.Query
  alias SubscriptionService.Repo

  @cancelled_statuses ["cancelled", "expired", "refunded"]

  def change do
    alter table("subscriptions") do
      add :archived,     :boolean, default: false, null: false
      add :archived_at,  :utc_datetime, null: true
      add :archive_reason, :string, null: true
    end

    create index("subscriptions", [:archived])
    create index("subscriptions", [:archived, :plan_id])

    flush()

    archive_cancelled_subscriptions()
  end

  defp archive_cancelled_subscriptions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in "subscriptions",
      where: s.status in ^@cancelled_statuses,
      update: [
        set: [
          archived:       true,
          archived_at:    ^now,
          archive_reason: "migrated_on_add_archived_column"
        ]
      ]
    )
    |> Repo.update_all([])
  end
end```
