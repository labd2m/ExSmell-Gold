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

    mark_stale_documents_archived()
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
