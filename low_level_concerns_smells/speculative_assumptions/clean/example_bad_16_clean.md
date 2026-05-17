```elixir
defmodule Logistics.FreightLegParser do
  @moduledoc """
  Parses freight route leg descriptors produced by the carrier tracking integration.

  Carrier tracking webhooks deliver route progress as a sequence of leg descriptors
  embedded in a pipe-delimited event string. Each leg descriptor encodes the location
  code, event type, and scheduled or actual timestamp:

    "<LOCATION_CODE>:<EVENT_TYPE>:<ISO8601_TIMESTAMP>"

  A full route string is a sequence of legs joined by ">":

    "SYD:DEP:2024-03-15T08:00:00Z>MEL:ARR:2024-03-15T09:45:00Z>MEL:DEP:2024-03-15T10:30:00Z"

  Supported event types:
    DEP  — Departed location
    ARR  — Arrived at location
    XDOC — Cross-docked
    HELD — Shipment held at location
  """

  require Logger

  @supported_events ~w(DEP ARR XDOC HELD)

  defstruct [:location_code, :event_type, :timestamp, :raw]

  @doc """
  Parses a complete route string into an ordered list of leg structs.
  """
  def parse_route(route_string) when is_binary(route_string) do
    route_string
    |> String.split(">")
    |> Enum.map(&extract_leg_detail/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, leg},      {:ok, acc} -> {:cont, {:ok, [leg | acc]}}
      {:error, reason}, _         -> {:halt, {:error, reason}}
    end)
    |> then(fn
      {:ok, legs}      -> {:ok, Enum.reverse(legs)}
      {:error, reason} -> {:error, reason}
    end)
  end

  @doc """
  Extracts a single leg descriptor string into a `%FreightLegParser{}` struct.
  """

  def extract_leg_detail(leg_str) when is_binary(leg_str) do
    parts         = String.split(leg_str, ":")
    location_code = Enum.at(parts, 0)
    event_type    = Enum.at(parts, 1)
    raw_timestamp = Enum.at(parts, 2)

    with :ok <- validate_event_type(event_type) do
      {:ok, %__MODULE__{
        location_code: location_code,
        event_type:    event_type,
        timestamp:     parse_timestamp(raw_timestamp),
        raw:           leg_str
      }}
    end
  end

  @doc """
  Returns the departure and arrival location codes from a parsed route.
  """
  def route_endpoints([first | _] = legs) do
    last = List.last(legs)
    %{origin: first.location_code, destination: last.location_code}
  end

  def route_endpoints([]), do: %{origin: nil, destination: nil}

  @doc """
  Returns only the DEP legs from a parsed route, in order.
  """
  def departures(legs) when is_list(legs) do
    Enum.filter(legs, &(&1.event_type == "DEP"))
  end

  @doc """
  Returns only the ARR legs from a parsed route, in order.
  """
  def arrivals(legs) when is_list(legs) do
    Enum.filter(legs, &(&1.event_type == "ARR"))
  end

  @doc """
  Returns true if there is a HELD event anywhere in the route.
  """
  def held_in_transit?(legs) when is_list(legs) do
    Enum.any?(legs, &(&1.event_type == "HELD"))
  end

  @doc """
  Formats a list of legs into a human-readable transit summary.
  """
  def format_summary(legs) when is_list(legs) do
    legs
    |> Enum.map(fn leg ->
      ts = if leg.timestamp, do: DateTime.to_string(leg.timestamp), else: "unknown time"
      "  #{leg.event_type} #{leg.location_code} at #{ts}"
    end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_event_type(evt) when is_binary(evt) do
    if evt in @supported_events do
      :ok
    else
      {:error, {:unsupported_event_type, evt}}
    end
  end

  defp validate_event_type(nil), do: {:error, :missing_event_type}
  defp validate_event_type(_),   do: {:error, :invalid_event_type}

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _                  ->
        Logger.warning("FreightLegParser: could not parse timestamp #{inspect(str)}")
        nil
    end
  end
end
```
