# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `consolidate_metadata/0`
- **Short explanation:** The migration adds a `metadata` JSONB column to `events` and then reads multiple existing columns from every row, consolidates those values into a JSON map, and writes the result back. Aggregating and restructuring existing column data into a new format is a data transformation step that must not reside inside an `Ecto.Migration`.

---

```elixir
defmodule Analytics.Repo.Migrations.AddMetadataToEvents do
  use Ecto.Migration

  import Ecto.Query
  alias Analytics.Repo

  def change do
    alter table("events") do
      add :metadata,         :map, null: true
      add :metadata_version, :integer, default: 1, null: false
    end

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after the structural change the
    # migration reads several discrete columns (browser, os, device_type,
    # referrer, ip_address) from every event row, constructs a consolidated
    # metadata map from them, and writes it back to the new metadata column.
    # This consolidation and reshaping of existing row data is a data
    # manipulation concern that reduces migration cohesion and should be
    # handled in a separate Mix task.
    consolidate_metadata()
    # VALIDATION: SMELL END
  end

  defp consolidate_metadata do
    rows =
      from(e in "events",
        select: %{
          id:          e.id,
          browser:     e.browser,
          os:          e.os,
          device_type: e.device_type,
          referrer:    e.referrer,
          ip_address:  e.ip_address
        }
      )
      |> Repo.all()

    Enum.each(rows, fn row ->
      metadata = %{
        "client" => %{
          "browser"     => row.browser,
          "os"          => row.os,
          "device_type" => row.device_type
        },
        "request" => %{
          "referrer"   => row.referrer,
          "ip_address" => row.ip_address
        }
      }

      from(e in "events", where: e.id == ^row.id)
      |> Repo.update_all(set: [metadata: metadata])
    end)
  end
end
```
