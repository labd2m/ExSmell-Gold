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

    consolidate_metadata()
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
