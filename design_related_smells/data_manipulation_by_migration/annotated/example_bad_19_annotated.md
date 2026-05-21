# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `derive_shipping_statuses/0`, `latest_status_from_events/1`
- **Affected functions:** `change/0`, `derive_shipping_statuses/0`, `latest_status_from_events/1`
- **Short explanation:** This migration adds a `current_status` column to `shipments` (structural change) and then queries the `shipment_events` table per shipment to derive and store the current status (data manipulation). Deriving data from event logs and updating a parent record inside a migration module is a clear violation of the separation of concerns this smell describes.

---

```elixir
defmodule Fulfillment.Repo.Migrations.AddCurrentStatusToShipments do
  use Ecto.Migration

  import Ecto.Query
  alias Fulfillment.Repo

  @terminal_statuses ["delivered", "failed", "returned", "cancelled"]

  @event_to_status %{
    "label_created"       => "label_created",
    "picked_up"           => "in_transit",
    "in_transit"          => "in_transit",
    "out_for_delivery"    => "out_for_delivery",
    "delivery_attempted"  => "delivery_attempted",
    "delivered"           => "delivered",
    "exception"           => "exception",
    "return_initiated"    => "returned",
    "cancelled"           => "cancelled"
  }

  def change do
    alter table("shipments") do
      add :current_status,    :string, null: true
      add :last_event_at,     :utc_datetime, null: true
    end

    create index("shipments", [:current_status])
    create index("shipments", [:current_status, :inserted_at])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration reads from the shipment_events
    # table per shipment and writes a derived current_status and last_event_at back
    # to shipments. Joining related tables and applying event-reduction logic is data
    # manipulation that must not reside in an Ecto.Migration module.
    derive_shipping_statuses()
    # VALIDATION: SMELL END
  end

  defp derive_shipping_statuses do
    shipment_ids =
      from(s in "shipments",
        where: is_nil(s.current_status),
        select: s.id
      )
      |> Repo.all()

    Enum.each(shipment_ids, fn shipment_id ->
      events =
        from(e in "shipment_events",
          where: e.shipment_id == ^shipment_id,
          order_by: [asc: e.occurred_at],
          select: %{event_type: e.event_type, occurred_at: e.occurred_at}
        )
        |> Repo.all()

      {status, last_event_at} = latest_status_from_events(events)

      from(s in "shipments", where: s.id == ^shipment_id)
      |> Repo.update_all(
        set: [
          current_status: status,
          last_event_at:  last_event_at
        ]
      )
    end)
  end

  defp latest_status_from_events([]), do: {"pending", nil}

  defp latest_status_from_events(events) do
    %{event_type: last_event, occurred_at: occurred_at} = List.last(events)
    status = Map.get(@event_to_status, last_event, "unknown")
    {status, occurred_at}
  end
end
```
