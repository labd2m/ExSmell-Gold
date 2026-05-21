# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `mark_stale_documents_archived/0`
- **Affected functions:** `change/0`, `mark_stale_documents_archived/0`
- **Short explanation:** This migration adds `is_archived` and `archived_at` columns to `documents` (structural change) and then immediately applies business rules — archiving all documents not updated in the past two years (data manipulation). Applying time-based business rules to existing rows during a migration conflates schema evolution with application-level data management.

---

```elixir
defmodule ContentStore.Repo.Migrations.AddArchivingFieldsToDocuments do
  use Ecto.Migration

  import Ecto.Query
  alias ContentStore.Repo

  @stale_threshold_days 730

  def change do
    alter table("documents") do
      add :is_archived, :boolean, default: false, null: false
      add :archived_at, :utc_datetime, null: true
      add :archive_reason, :string, null: true, size: 100
    end

    create index("documents", [:is_archived])
    create index("documents", [:is_archived, :inserted_at])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration evaluates a staleness rule
    # against existing document rows and updates their is_archived, archived_at,
    # and archive_reason columns. Applying business rules to existing data is data
    # manipulation and should be performed in a Mix task, not in a migration module.
    mark_stale_documents_archived()
    # VALIDATION: SMELL END
  end

  defp mark_stale_documents_archived do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-@stale_threshold_days, :day)
    now = DateTime.utc_now()

    from(d in "documents",
      where:
        d.is_archived == false and
          (is_nil(d.updated_at) or d.updated_at < ^cutoff_date)
    )
    |> Repo.update_all(
      set: [
        is_archived:    true,
        archived_at:    now,
        archive_reason: "stale_auto_archive"
      ]
    )
  end
end
```
