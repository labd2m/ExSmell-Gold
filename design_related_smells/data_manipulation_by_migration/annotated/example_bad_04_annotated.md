# Annotated Bad Example 04

## Metadata

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function in `AddTrackingStateToShipments`
- **Affected function(s):** `change/0`, `backfill_tracking_states/0`, `derive_tracking_state/1`
- **Short explanation:** The migration adds a `tracking_state` column to the `shipments` table (schema change) and also reads existing shipment records to derive and write the initial tracking state (data manipulation). The data backfill logic should be extracted to a Mix task.

---

## Code

```elixir
defmodule Logistics.Repo.Migrations.AddTrackingStateToShipments do
  use Ecto.Migration

  # VALIDATION: SMELL START - Data manipulation by migration
  # VALIDATION: This is a smell because the migration mixes DDL (adding :tracking_state
  # and :tracking_state_changed_at columns) with DML (reading existing shipments and
  # writing derived tracking states). Ecto.Migration modules should be restricted to
  # schema changes only.

  import Ecto.Query
  alias Logistics.Shipments.Shipment
  alias Logistics.Repo

  def change do
    alter table("shipments") do
      add :tracking_state, :string, null: false, default: "untracked"
      add :tracking_state_changed_at, :utc_datetime
      add :last_carrier_event, :string
    end

    create index("shipments", [:tracking_state])
    create index("shipments", [:tracking_state_changed_at])

    flush()

    backfill_tracking_states()
  end

  defp backfill_tracking_states do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Shipment,
      where: not is_nil(s.carrier_tracking_number),
      select: %{
        id: s.id,
        dispatched_at: s.dispatched_at,
        estimated_delivery_at: s.estimated_delivery_at,
        delivered_at: s.delivered_at
      }
    )
    |> Repo.all()
    |> Enum.each(fn shipment ->
      state = derive_tracking_state(shipment)

      from(s in Shipment, where: s.id == ^shipment.id)
      |> Repo.update_all(
        set: [
          tracking_state: state,
          tracking_state_changed_at: now
        ]
      )
    end)
  end

  defp derive_tracking_state(%{delivered_at: delivered_at}) when not is_nil(delivered_at),
    do: "delivered"

  defp derive_tracking_state(%{estimated_delivery_at: eta}) when not is_nil(eta),
    do: "in_transit"

  defp derive_tracking_state(%{dispatched_at: dispatched_at}) when not is_nil(dispatched_at),
    do: "dispatched"

  defp derive_tracking_state(_), do: "untracked"

  # VALIDATION: SMELL END
end
```
