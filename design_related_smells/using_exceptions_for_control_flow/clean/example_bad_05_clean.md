```elixir
defmodule Logistics.Carrier do
  @moduledoc "Enumerates supported carrier codes and their display names."

  @carriers %{
    "UPS" => "United Parcel Service",
    "FEDEX" => "FedEx",
    "USPS" => "United States Postal Service",
    "DHL" => "DHL Express"
  }

  def known?(code), do: Map.has_key?(@carriers, code)
  def name(code), do: Map.get(@carriers, code, "Unknown")
  def all_codes, do: Map.keys(@carriers)
end

defmodule Logistics.TrackingEvent do
  @moduledoc "Represents a single event in a shipment's tracking history."

  @enforce_keys [:timestamp, :location, :description, :status]
  defstruct [:timestamp, :location, :description, :status]
end

defmodule Logistics.TrackingResult do
  @moduledoc "Aggregated tracking result returned to callers."

  defstruct [:tracking_number, :carrier, :current_status, :estimated_delivery, :events]
end

defmodule Logistics.CarrierGateway do
  @moduledoc "Simulates HTTP calls to carrier tracking APIs."

  alias Logistics.TrackingEvent

  def query("UNKNOWN_TNT", _carrier), do: {:error, :not_found}
  def query(_number, "SLOW_CARRIER"), do: {:error, :timeout}

  def query(number, carrier) do
    event = %TrackingEvent{
      timestamp: DateTime.utc_now(),
      location: "Chicago, IL",
      description: "Package in transit",
      status: :in_transit
    }

    {:ok,
     %{
       tracking_number: number,
       carrier: carrier,
       current_status: :in_transit,
       estimated_delivery: Date.add(Date.utc_today(), 2),
       events: [event]
     }}
  end
end

defmodule Logistics.TrackingClient do
  @moduledoc """
  Retrieves real-time shipment status from the appropriate carrier gateway.
  Validates the tracking number format and carrier code before querying.
  """

  alias Logistics.{Carrier, CarrierGateway, TrackingResult}
  require Logger

  @min_tracking_length 8
  @max_tracking_length 40

  def fetch_status({tracking_number, carrier_code})
      when is_binary(tracking_number) and is_binary(carrier_code) do
    len = String.length(tracking_number)

    if len < @min_tracking_length or len > @max_tracking_length do
      raise RuntimeError,
        message:
          "Tracking number '#{tracking_number}' has invalid length #{len}. " <>
            "Expected between #{@min_tracking_length} and #{@max_tracking_length} characters."
    end

    unless Carrier.known?(carrier_code) do
      raise RuntimeError,
        message:
          "Carrier '#{carrier_code}' is not supported. " <>
            "Supported carriers: #{Enum.join(Carrier.all_codes(), ", ")}"
    end

    case CarrierGateway.query(tracking_number, carrier_code) do
      {:ok, raw} ->
        result = %TrackingResult{
          tracking_number: raw.tracking_number,
          carrier: Carrier.name(carrier_code),
          current_status: raw.current_status,
          estimated_delivery: raw.estimated_delivery,
          events: raw.events
        }

        Logger.debug("Fetched tracking for #{tracking_number} via #{carrier_code}")
        result

      {:error, :not_found} ->
        raise RuntimeError,
          message: "Tracking number '#{tracking_number}' was not found at #{carrier_code}"

      {:error, :timeout} ->
        raise RuntimeError,
          message: "Carrier #{carrier_code} did not respond in time for #{tracking_number}"

      {:error, reason} ->
        raise RuntimeError,
          message: "Unexpected error from #{carrier_code}: #{inspect(reason)}"
    end
  end
end

defmodule Logistics.ShipmentDashboard do
  @moduledoc """
  Loads tracking statuses for multiple shipments and aggregates
  them for display in the operations dashboard.
  """

  alias Logistics.TrackingClient
  require Logger

  def load_statuses(shipments) when is_list(shipments) do
    Enum.map(shipments, fn %{id: id, tracking_number: tn, carrier: carrier} ->
      # Client is forced to use try/rescue because TrackingClient.fetch_status/1
      # raises on all error paths instead of returning {:error, reason}.
      try do
        result = TrackingClient.fetch_status({tn, carrier})

        %{
          shipment_id: id,
          status: :loaded,
          tracking: result
        }
      rescue
        e in RuntimeError ->
          Logger.warning("Could not load tracking for shipment=#{id}: #{e.message}")

          %{
            shipment_id: id,
            status: :error,
            reason: e.message
          }
      end
    end)
  end

  def summarise(statuses) do
    loaded = Enum.count(statuses, &(&1.status == :loaded))
    errored = Enum.count(statuses, &(&1.status == :error))
    %{total: length(statuses), loaded: loaded, errored: errored}
  end
end
```
