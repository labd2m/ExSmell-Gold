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

    derive_shipping_statuses()
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
