# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Logistics.Shipment.track/2`
- **Affected function(s):** `track/2`
- **Short explanation:** The `:detail` option causes the function to return either a simple atom status, a keyword list of events, or a full map with carrier information. The three shapes are incompatible and force every caller to be aware of which option was used before processing the result.

---

```elixir
defmodule MyApp.Logistics.Shipment do
  @moduledoc """
  Tracks shipment status and history across multiple carrier integrations.
  Supports querying the latest status or full event history for a given
  tracking number.
  """

  alias MyApp.Logistics.CarrierAdapter
  alias MyApp.Logistics.EventLog
  alias MyApp.Logistics.GeoResolver

  @carriers [:correios, :fedex, :dhl, :ups]
  @terminal_statuses [:delivered, :returned, :lost]

  def new(attrs) do
    %{
      tracking_number: attrs[:tracking_number],
      carrier: attrs[:carrier],
      origin: attrs[:origin],
      destination: attrs[:destination],
      weight_g: attrs[:weight_g],
      created_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:detail] changes the shape of what
  # is returned completely: :status returns a plain atom like :in_transit,
  # :events returns a keyword list of timestamped events, and :full (default)
  # returns a rich map. These three shapes have nothing in common structurally,
  # making it impossible for callers to write generic handling code.
  def track(tracking_number, opts \\ []) when is_list(opts) do
    detail = Keyword.get(opts, :detail, :full)
    carrier = Keyword.get(opts, :carrier, :auto)
    resolve_location = Keyword.get(opts, :resolve_location, false)

    resolved_carrier = if carrier == :auto, do: detect_carrier(tracking_number), else: carrier

    with {:ok, raw_events} <- CarrierAdapter.fetch_events(resolved_carrier, tracking_number) do
      latest = List.last(raw_events)

      case detail do
        :status ->
          latest.status

        :events ->
          Enum.map(raw_events, fn e ->
            [status: e.status, timestamp: e.timestamp, location: e.location]
          end)

        :full ->
          enriched_events =
            if resolve_location do
              Enum.map(raw_events, fn e ->
                coords = GeoResolver.resolve(e.location)
                Map.put(e, :coordinates, coords)
              end)
            else
              raw_events
            end

          %{
            tracking_number: tracking_number,
            carrier: resolved_carrier,
            current_status: latest.status,
            last_updated: latest.timestamp,
            last_location: latest.location,
            terminal: latest.status in @terminal_statuses,
            events: enriched_events,
            event_count: length(raw_events)
          }
      end
    end
  end
  # VALIDATION: SMELL END

  def register(shipment, carrier) when carrier in @carriers do
    CarrierAdapter.register(carrier, shipment)
  end

  def cancel(tracking_number, reason) do
    EventLog.append(tracking_number, :cancelled, %{reason: reason, at: DateTime.utc_now()})
  end

  def estimated_delivery(tracking_number) do
    with {:ok, events} <- CarrierAdapter.fetch_events(:auto, tracking_number) do
      events
      |> Enum.find(&(&1.status == :out_for_delivery))
      |> case do
        nil -> {:unknown}
        event -> {:ok, Date.add(event.timestamp, 1)}
      end
    end
  end

  defp detect_carrier("JD" <> _), do: :correios
  defp detect_carrier("7" <> _), do: :fedex
  defp detect_carrier("1Z" <> _), do: :ups
  defp detect_carrier(_), do: :dhl
end
```
