```elixir
# ── file: lib/logistics/shipment.ex ──────────────────────────────────────────

defmodule Logistics.Shipment do
  @moduledoc """
  Core shipment entity. Handles creation and routing of outbound packages
  across the carrier network. Invoked by the order fulfillment pipeline.
  """

  alias Logistics.{Carrier, Address, PackageDimensions, RoutingEngine}

  @type status ::
          :pending
          | :picked_up
          | :in_transit
          | :out_for_delivery
          | :delivered
          | :failed
          | :returned

  @type t :: %__MODULE__{
          id: String.t(),
          order_id: String.t(),
          carrier_code: String.t(),
          tracking_number: String.t() | nil,
          origin: Address.t(),
          destination: Address.t(),
          dimensions: PackageDimensions.t(),
          weight_grams: pos_integer(),
          status: status(),
          estimated_delivery: Date.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :order_id,
    :carrier_code,
    :tracking_number,
    :origin,
    :destination,
    :dimensions,
    :weight_grams,
    :estimated_delivery,
    status: :pending,
    created_at: nil
  ]

  @spec create(map()) :: {:ok, t()} | {:error, String.t()}
  def create(attrs) do
    with {:ok, origin} <- Address.validate(attrs[:origin]),
         {:ok, destination} <- Address.validate(attrs[:destination]),
         {:ok, carrier} <- Carrier.select(attrs[:carrier_code]),
         {:ok, route} <- RoutingEngine.plan(origin, destination, carrier) do
      shipment = %__MODULE__{
        id: generate_id(),
        order_id: attrs[:order_id],
        carrier_code: carrier.code,
        tracking_number: nil,
        origin: origin,
        destination: destination,
        dimensions: attrs[:dimensions],
        weight_grams: attrs[:weight_grams],
        estimated_delivery: route.estimated_delivery,
        status: :pending,
        created_at: DateTime.utc_now()
      }

      {:ok, shipment}
    end
  end

  @spec assign_tracking(t(), String.t()) :: {:ok, t()}
  def assign_tracking(%__MODULE__{} = shipment, tracking_number) do
    {:ok, %{shipment | tracking_number: tracking_number, status: :picked_up}}
  end

  @spec cancel(t()) :: {:ok, t()} | {:error, String.t()}
  def cancel(%__MODULE__{status: :pending} = shipment) do
    {:ok, %{shipment | status: :returned}}
  end

  def cancel(%__MODULE__{}), do: {:error, "cannot cancel a shipment that has been picked up"}

  defp generate_id do
    "SHP-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end


# ── file: lib/logistics/shipment_tracking.ex ─────────────────────────────────

defmodule Logistics.Shipment do
  @moduledoc """
  Handles real-time tracking updates for shipments in transit.
  Receives webhooks from carrier APIs and updates the shipment timeline.
  """

  alias Logistics.{TrackingEvent, CarrierWebhook, Repo}

  @terminal_statuses [:delivered, :failed, :returned]

  @spec track(String.t()) :: {:ok, [TrackingEvent.t()]} | {:error, :not_found}
  def track(tracking_number) do
    case Repo.get_by(:shipments, tracking_number: tracking_number) do
      nil -> {:error, :not_found}
      shipment -> {:ok, Repo.all(:tracking_events, shipment_id: shipment.id)}
    end
  end

  @spec handle_webhook(CarrierWebhook.t()) :: :ok | {:error, term()}
  def handle_webhook(%CarrierWebhook{tracking_number: tn, event_type: type, occurred_at: ts}) do
    case Repo.get_by(:shipments, tracking_number: tn) do
      nil ->
        {:error, :shipment_not_found}

      shipment ->
        new_status = map_carrier_status(type)

        event = %TrackingEvent{
          shipment_id: shipment.id,
          event_type: type,
          status: new_status,
          occurred_at: ts,
          recorded_at: DateTime.utc_now()
        }

        unless shipment.status in @terminal_statuses do
          Repo.update(:shipments, shipment.id, %{status: new_status})
        end

        Repo.insert(:tracking_events, event)
        :ok
    end
  end

  @spec latest_status(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def latest_status(tracking_number) do
    case Repo.get_by(:shipments, tracking_number: tracking_number) do
      nil -> {:error, :not_found}
      shipment -> {:ok, shipment.status}
    end
  end

  defp map_carrier_status("picked_up"), do: :picked_up
  defp map_carrier_status("in_transit"), do: :in_transit
  defp map_carrier_status("out_for_delivery"), do: :out_for_delivery
  defp map_carrier_status("delivered"), do: :delivered
  defp map_carrier_status("exception"), do: :failed
  defp map_carrier_status(_), do: :in_transit
end
```
