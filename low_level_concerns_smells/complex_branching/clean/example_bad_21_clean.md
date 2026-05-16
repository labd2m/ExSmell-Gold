```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Integrates with carrier APIs to fetch real-time shipment tracking data.
  Normalises carrier-specific responses into a unified tracking event format.
  """

  require Logger

  alias Logistics.{Shipment, TrackingEvent, Carrier}
  alias Logistics.Repo

  @retry_after_default 300

  def sync_shipment(shipment_id) do
    with {:ok, shipment} <- Shipment.fetch(shipment_id),
         {:ok, carrier} <- Carrier.for_shipment(shipment),
         {:ok, result} <- fetch_tracking_events(carrier, shipment.tracking_number) do
      persist_events(shipment, result)
    end
  end

  def sync_all_active do
    Shipment.list_active()
    |> Enum.each(fn shipment ->
      case sync_shipment(shipment.id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to sync shipment #{shipment.id}: #{inspect(reason)}")
      end
    end)
  end

  def mark_delivered(shipment_id) do
    with {:ok, shipment} <- Shipment.fetch(shipment_id) do
      shipment
      |> Shipment.mark_delivered(DateTime.utc_now())
      |> Repo.update()
    end
  end

  defp fetch_tracking_events(%Carrier{} = carrier, tracking_number) do
    CarrierAPI.get_tracking(carrier.code, tracking_number)
    |> parse_tracking_response()
  end

  defp parse_tracking_response(response) do
    case response do
      {:ok, %{status: 200, body: %{"events" => events, "estimated_delivery" => eta}}} ->
        {:ok, %{events: normalize_events(events), estimated_delivery: eta}}

      {:ok, %{status: 200, body: %{"events" => events}}} ->
        {:ok, %{events: normalize_events(events), estimated_delivery: nil}}

      {:ok, %{status: 202}} ->
        Logger.info("Tracking data not yet available from carrier")
        {:pending, :not_ready}

      {:ok, %{status: 204}} ->
        {:ok, %{events: [], estimated_delivery: nil}}

      {:ok, %{status: 400, body: %{"error" => "invalid_tracking_number"}}} ->
        {:error, :invalid_tracking_number}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        Logger.warning("Bad request to carrier API: #{msg}")
        {:error, {:bad_request, msg}}

      {:ok, %{status: 401}} ->
        Logger.error("Unauthorised request to carrier API")
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        Logger.error("Access forbidden by carrier API")
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :tracking_number_not_found}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Carrier API rate limited, retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 503}} ->
        Logger.warning("Carrier API temporarily unavailable")
        {:error, :service_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected carrier API response #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, :timeout} ->
        Logger.warning("Carrier API request timed out")
        {:error, :timeout}

      {:error, :econnrefused} ->
        Logger.error("Could not connect to carrier API")
        {:error, :connection_refused}

      {:error, reason} ->
        Logger.error("Carrier API client error: #{inspect(reason)}")
        {:error, {:client_error, reason}}
    end
  end

  defp normalize_events(events) do
    Enum.map(events, fn event ->
      %TrackingEvent{
        code: event["code"],
        description: event["description"],
        location: event["location"],
        occurred_at: parse_datetime(event["timestamp"])
      }
    end)
  end

  defp persist_events(shipment, %{events: events, estimated_delivery: eta}) do
    Repo.transaction(fn ->
      Enum.each(events, fn event ->
        TrackingEvent.upsert!(event, shipment_id: shipment.id)
      end)

      if eta do
        shipment
        |> Shipment.update_eta(eta)
        |> Repo.update!()
      end
    end)
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> @retry_after_default
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
```
