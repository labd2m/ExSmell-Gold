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

    generate_tracking_tokens()
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
end```
