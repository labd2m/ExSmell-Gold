# Code Smell Example 49

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `generate_tracking_tokens/0`
- **Short explanation:** The migration adds a `tracking_token` column to `shipments` (structural change) and then generates and persists a unique token for every existing shipment row (data manipulation), embedding token-generation logic that belongs in the application layer or a dedicated Mix task.

```elixir
defmodule LogisticsApp.Repo.Migrations.AddTrackingTokenToShipments do
  use Ecto.Migration

  import Ecto.Query
  alias LogisticsApp.Repo

  def change do
    alter table("shipments") do
      add :tracking_token,          :string, null: true
      add :tracking_token_issued_at, :utc_datetime, null: true
    end

    create unique_index("shipments", [:tracking_token])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because, beyond adding the column (structural
    # change), the migration fetches all existing shipment IDs, generates a
    # cryptographic token for each one, and writes those tokens back to the
    # database (data manipulation). Token generation is application-layer logic
    # that should not reside inside a migration module.
    generate_tracking_tokens()
    # VALIDATION: SMELL END
  end

  defp generate_tracking_tokens do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    shipment_ids =
      from(s in "shipments",
        where: is_nil(s.tracking_token),
        select: s.id
      )
      |> Repo.all()

    Enum.each(shipment_ids, fn id ->
      token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

      from(s in "shipments",
        where: s.id == ^id,
        update: [
          set: [
            tracking_token:           ^token,
            tracking_token_issued_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])
    end)
  end
end
```
