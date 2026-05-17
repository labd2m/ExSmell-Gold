```elixir
defmodule Logistics.ShipmentStatus do
  @moduledoc """
  Decodes raw shipment tracking events received from the carrier webhook.

  Expected event format (pipe-delimited):
    TRACKING_CODE|EVENT_CODE|TIMESTAMP|LOCATION|DESCRIPTION

  Example:
    BR123456789|DEL|2024-03-15T14:22:00Z|São Paulo, SP|Package delivered to recipient
  """

  require Logger

  @event_codes %{
    "DEL" => :delivered,
    "OFD" => :out_for_delivery,
    "INT" => :in_transit,
    "EXC" => :exception,
    "RTN" => :returned,
    "PKD" => :picked_up,
    "SRT" => :sorting,
    "CLS" => :customs_clearance
  }

  def process_webhook(payload) when is_binary(payload) do
    payload
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&decode_event/1)
    |> Enum.reject(&match?({:error, _}, &1))
    |> Enum.map(fn {:ok, event} -> event end)
  end

  defp decode_event(raw) do
    parts = String.split(raw, "|")

    tracking_code = Enum.at(parts, 0)
    event_code    = Enum.at(parts, 1)
    timestamp_str = Enum.at(parts, 2)
    location      = Enum.at(parts, 3)
    description   = Enum.at(parts, 4)

    status = Map.get(@event_codes, event_code, :unknown)

    timestamp =
      case DateTime.from_iso8601(timestamp_str || "") do
        {:ok, dt, _} -> dt
        _            -> nil
      end

    event = %{
      tracking_code: tracking_code,
      status:        status,
      raw_code:      event_code,
      timestamp:     timestamp,
      location:      location,
      description:   description
    }

    {:ok, event}
  end

  def latest_event(events) when is_list(events) do
    events
    |> Enum.reject(&is_nil(&1.timestamp))
    |> Enum.max_by(& &1.timestamp, DateTime, fn -> nil end)
  end

  def delivered?(events) do
    Enum.any?(events, &(&1.status == :delivered))
  end

  def exception?(events) do
    Enum.any?(events, &(&1.status == :exception))
  end

  def event_timeline(events) do
    events
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.map(&format_event/1)
  end

  defp format_event(%{status: status, timestamp: ts, location: loc, description: desc}) do
    ts_str = if ts, do: DateTime.to_string(ts), else: "unknown time"
    "#{ts_str} [#{status}] #{loc} — #{desc}"
  end

  def group_by_status(events) do
    Enum.group_by(events, & &1.status)
  end

  def tracking_summary(events, tracking_code) do
    relevant = Enum.filter(events, &(&1.tracking_code == tracking_code))

    %{
      tracking_code: tracking_code,
      event_count:   length(relevant),
      latest:        latest_event(relevant),
      delivered:     delivered?(relevant),
      has_exception: exception?(relevant)
    }
  end
end
```
