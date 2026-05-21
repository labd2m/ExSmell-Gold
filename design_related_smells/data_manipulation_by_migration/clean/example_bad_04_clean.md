```elixir
defmodule Logistics.Repo.Migrations.AddTrackingStateToShipments do
  use Ecto.Migration


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

end
```
