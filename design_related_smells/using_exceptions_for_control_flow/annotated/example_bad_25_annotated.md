# Annotated Example 25

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `CarrierClient.fetch_status/1` (library) and `ShipmentPoller.refresh/1` (client)
- **Affected function(s):** `CarrierClient.fetch_status/1`, `ShipmentPoller.refresh/1`
- **Short explanation:** `CarrierClient.fetch_status/1` raises exceptions for tracking-number-not-found, carrier API timeouts, and unknown carrier codes — all of which are common and anticipated in a logistics polling loop. By not providing a tuple-returning version, it forces `ShipmentPoller.refresh/1` to use `try...rescue` as ordinary polling control flow.

```elixir
defmodule CarrierClient do
  @moduledoc """
  Fetches real-time shipment status updates from carrier APIs.
  Supports UPS, FedEx, and USPS integrations.
  """

  defmodule TrackingNotFoundError do
    defexception [:message, :tracking_number, :carrier]
  end

  defmodule CarrierTimeoutError do
    defexception [:message, :carrier, :elapsed_ms]
  end

  defmodule UnsupportedCarrierError do
    defexception [:message, :carrier]
  end

  defmodule InvalidTrackingNumberError do
    defexception [:message, :tracking_number]
  end

  @supported_carriers ~w(ups fedex usps dhl)
  @timeout_ms 5_000

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because a tracking number not yet scanned into
  # the carrier system, a transient timeout, or an unsupported carrier are all
  # routine operational states for a shipment poller. Raising exceptions for
  # these cases — with no tuple-based alternative — means every polling cycle
  # that hits these states must be managed via try...rescue.
  def fetch_status(tracking_number) when not is_binary(tracking_number) or tracking_number == "" do
    raise InvalidTrackingNumberError,
      message: "Tracking number must be a non-empty string",
      tracking_number: tracking_number
  end

  def fetch_status(tracking_number) do
    carrier = detect_carrier(tracking_number)

    unless carrier in @supported_carriers do
      raise UnsupportedCarrierError,
        message: "Carrier '#{carrier}' is not supported; supported: #{Enum.join(@supported_carriers, ", ")}",
        carrier: carrier
    end

    start = System.monotonic_time(:millisecond)
    result = simulate_carrier_api(carrier, tracking_number)
    elapsed = System.monotonic_time(:millisecond) - start

    case result do
      :timeout ->
        raise CarrierTimeoutError,
          message: "Carrier #{carrier} API timed out after #{elapsed}ms",
          carrier: carrier,
          elapsed_ms: elapsed

      :not_found ->
        raise TrackingNotFoundError,
          message: "Tracking number '#{tracking_number}' not found at #{carrier}",
          tracking_number: tracking_number,
          carrier: carrier

      {:ok, status_payload} ->
        Map.merge(status_payload, %{
          tracking_number: tracking_number,
          carrier: carrier,
          fetched_at: DateTime.utc_now()
        })
    end
  end
  # VALIDATION: SMELL END

  defp detect_carrier("1Z" <> _), do: "ups"
  defp detect_carrier("7" <> _), do: "fedex"
  defp detect_carrier("9" <> _), do: "usps"
  defp detect_carrier("JD" <> _), do: "dhl"
  defp detect_carrier(_), do: "unknown"

  defp simulate_carrier_api("ups", "1ZTIMEOUT" <> _), do: :timeout
  defp simulate_carrier_api("fedex", "7NOTFOUND" <> _), do: :not_found

  defp simulate_carrier_api(_carrier, _tracking_number) do
    {:ok,
     %{
       status: :in_transit,
       location: "Memphis, TN",
       estimated_delivery: ~D[2025-09-14],
       events: [
         %{timestamp: ~U[2025-09-12 10:00:00Z], description: "Departed facility"},
         %{timestamp: ~U[2025-09-11 22:00:00Z], description: "Arrived at sorting facility"}
       ]
     }}
  end
end

defmodule ShipmentPoller do
  @moduledoc """
  Periodically refreshes shipment tracking data and updates order records.
  """

  require Logger

  def refresh(%{tracking_number: tracking_number, order_id: order_id} = shipment) do
    Logger.debug("Polling carrier status for order #{order_id} / #{tracking_number}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because in a normal polling loop, timeouts
    # and "not yet tracked" states are expected outcomes, not true exceptions.
    # The client has no choice but to use try...rescue since CarrierClient
    # provides no tuple-based API.
    try do
      status = CarrierClient.fetch_status(tracking_number)

      Logger.info(
        "Order #{order_id} status: #{status.status}, location: #{status.location}"
      )

      {:ok, Map.merge(shipment, %{last_status: status, last_polled_at: DateTime.utc_now()})}
    rescue
      e in CarrierClient.TrackingNotFoundError ->
        Logger.debug("Tracking #{e.tracking_number} not yet in #{e.carrier} system; will retry")
        {:pending, :not_yet_scanned}

      e in CarrierClient.CarrierTimeoutError ->
        Logger.warning("Carrier #{e.carrier} timed out after #{e.elapsed_ms}ms for order #{order_id}")
        {:error, :carrier_timeout}

      e in CarrierClient.UnsupportedCarrierError ->
        Logger.error("Unsupported carrier for order #{order_id}: #{e.message}")
        {:error, {:unsupported_carrier, e.carrier}}

      e in CarrierClient.InvalidTrackingNumberError ->
        Logger.error("Invalid tracking number on order #{order_id}: #{e.message}")
        {:error, :invalid_tracking_number}
    end
    # VALIDATION: SMELL END
  end

  def refresh_batch(shipments) do
    Enum.map(shipments, &refresh/1)
  end
end
```
