# Code Smell Example 47

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `archive_cancelled_subscriptions/0`
- **Short explanation:** The migration adds an `archived` boolean column to `subscriptions` (structural change) and then queries rows whose status is `"cancelled"` and marks them as archived (data manipulation), embedding status-based business logic inside a schema migration.

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration does not stop at DDL —
    # it also executes a DML query that reads subscription status values and
    # updates rows to mark them archived. Business-rule-driven backfill like this
    # should be isolated in a Mix task, not embedded inside a migration module.
    archive_cancelled_subscriptions()
    # VALIDATION: SMELL END
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
end
```
