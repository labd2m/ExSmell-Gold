# Code Smell Annotation

- **Smell name:** Complex branching
- **Expected smell location:** `CarrierClient.fetch_tracking/2`, the large `case` handling every carrier API response variant
- **Affected function(s):** `fetch_tracking/2`
- **Short explanation:** All carrier tracking response variants — delivered, in-transit, out-for-delivery, exception sub-codes, invalid tracking numbers, expired shipments, API auth failures, rate limits, and timeouts — are handled inside a single function. Each branch embeds its own logging and downstream side effects. The function's cyclomatic complexity grows with every new carrier event code added, making it a maintenance bottleneck and a likely source of regression bugs.

```elixir
defmodule MyApp.Logistics.CarrierClient do
  @moduledoc """
  Client for querying parcel tracking status from the unified carrier gateway.
  Supports UPS, FedEx, DHL, and USPS via a single aggregation endpoint.
  """

  require Logger

  alias MyApp.Logistics.{ShipmentRecord, TrackingEventLog, AlertDispatcher}

  @api_base "https://api.carriergateway.io/v3"
  @http_timeout_ms 12_000
  @exception_alert_codes ~w(DAMAGED LOST ADDRESS_ISSUE CUSTOMS_HOLD)

  @spec fetch_tracking(String.t(), String.t()) ::
          {:ok, map()} | {:error, atom() | map()}
  def fetch_tracking(tracking_number, carrier) do
    headers = build_headers()
    url = "#{@api_base}/track/#{carrier}/#{tracking_number}"

    Logger.debug("Fetching tracking: #{tracking_number} carrier=#{carrier}")

    # VALIDATION: SMELL START - Complex branching
    # VALIDATION: This is a smell because `fetch_tracking/2` alone branches on
    # VALIDATION: every possible API outcome: HTTP 200 with multiple status values
    # VALIDATION: (delivered, in_transit, out_for_delivery, exception — itself with
    # VALIDATION: sub-codes), 400 invalid number, 404 not found, 410 expired, 401,
    # VALIDATION: 429, 5xx errors, timeout, and generic network failures. Each branch
    # VALIDATION: performs different logging and side effects. The cyclomatic complexity
    # VALIDATION: makes this function very hard to test and evolve safely.
    case HTTPoison.get(url, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parsed = Jason.decode!(body)

        case parsed["status"] do
          "DELIVERED" ->
            event = %{
              tracking_number: tracking_number,
              status: :delivered,
              location: parsed["last_location"],
              timestamp: parsed["delivered_at"]
            }
            TrackingEventLog.record(event)
            ShipmentRecord.mark_delivered(tracking_number, parsed["delivered_at"])
            Logger.info("Parcel delivered: #{tracking_number} at #{parsed["delivered_at"]}")
            {:ok, event}

          "OUT_FOR_DELIVERY" ->
            event = %{
              tracking_number: tracking_number,
              status: :out_for_delivery,
              location: parsed["current_location"],
              eta: parsed["estimated_delivery"]
            }
            TrackingEventLog.record(event)
            Logger.info("Parcel out for delivery: #{tracking_number}")
            {:ok, event}

          "IN_TRANSIT" ->
            event = %{
              tracking_number: tracking_number,
              status: :in_transit,
              location: parsed["current_location"],
              eta: parsed["estimated_delivery"],
              checkpoints: parsed["checkpoints"]
            }
            TrackingEventLog.record(event)
            {:ok, event}

          "EXCEPTION" ->
            exception_code = parsed["exception_code"]

            if exception_code in @exception_alert_codes do
              AlertDispatcher.send_exception_alert(tracking_number, exception_code, parsed["exception_description"])
              Logger.warning("Tracking exception alert sent: #{tracking_number} code=#{exception_code}")
            else
              Logger.warning("Tracking exception: #{tracking_number} code=#{exception_code}")
            end

            ShipmentRecord.flag_exception(tracking_number, exception_code)
            event = %{tracking_number: tracking_number, status: :exception, code: exception_code,
                      description: parsed["exception_description"]}
            TrackingEventLog.record(event)
            {:ok, event}

          "PENDING" ->
            event = %{tracking_number: tracking_number, status: :pending, message: parsed["message"]}
            {:ok, event}

          "RETURNED" ->
            event = %{tracking_number: tracking_number, status: :returned, reason: parsed["return_reason"]}
            ShipmentRecord.mark_returned(tracking_number)
            TrackingEventLog.record(event)
            Logger.info("Parcel returned: #{tracking_number} reason=#{parsed["return_reason"]}")
            {:ok, event}

          unknown ->
            Logger.warning("Unknown tracking status: #{unknown} for #{tracking_number}")
            {:error, {:unknown_status, unknown}}
        end

      {:ok, %HTTPoison.Response{status_code: 400, body: body}} ->
        parsed = Jason.decode!(body)
        Logger.warning("Invalid tracking number format: #{tracking_number}")
        {:error, {:invalid_tracking_number, parsed["message"]}}

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("Carrier API authentication failed")
        {:error, :authentication_failed}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        Logger.info("Tracking number not found: #{tracking_number}")
        {:error, :tracking_not_found}

      {:ok, %HTTPoison.Response{status_code: 410}} ->
        Logger.info("Tracking record expired: #{tracking_number}")
        {:error, :tracking_expired}

      {:ok, %HTTPoison.Response{status_code: 429, body: body}} ->
        parsed = Jason.decode!(body)
        retry_after = parsed["retry_after_seconds"] || 60
        Logger.warning("Carrier API rate limited, retry_after=#{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("Carrier API server error: status=#{status}")
        {:error, :carrier_api_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("Carrier API timeout for tracking_number=#{tracking_number}")
        {:error, :carrier_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Carrier API network error: #{inspect(reason)}")
        {:error, :network_error}
    end
    # VALIDATION: SMELL END
  end

  @spec batch_track([{String.t(), String.t()}]) :: [map()]
  def batch_track(shipments) do
    Enum.map(shipments, fn {tracking_number, carrier} ->
      case fetch_tracking(tracking_number, carrier) do
        {:ok, event} -> event
        {:error, reason} -> %{tracking_number: tracking_number, error: reason}
      end
    end)
  end

  # Private helpers

  defp build_headers do
    api_key = Application.fetch_env!(:my_app, :carrier_gateway_api_key)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "application/json"},
      {"X-Client-Version", "2.1.0"}
    ]
  end
end
```
