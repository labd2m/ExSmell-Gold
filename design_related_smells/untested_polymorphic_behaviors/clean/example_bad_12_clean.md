```elixir
defmodule Logistics.Tracking do
  @moduledoc """
  Handles shipment tracking operations including carrier code normalization,
  tracking URL generation, and status event formatting for the logistics dashboard.
  """

  @carriers %{
    "FEDEX" => "https://www.fedex.com/tracking?tracknumbers=",
    "UPS" => "https://www.ups.com/track?tracknum=",
    "DHL" => "https://www.dhl.com/track?tracking-id=",
    "CORREIOS" => "https://rastreamento.correios.com.br/app/index.php?objeto="
  }

  @status_labels %{
    "IN_TRANSIT" => "In Transit",
    "OUT_FOR_DELIVERY" => "Out for Delivery",
    "DELIVERED" => "Delivered",
    "EXCEPTION" => "Delivery Exception",
    "RETURNED" => "Returned to Sender",
    "PENDING" => "Pending Pickup"
  }

  @doc """
  Normalizes a raw carrier code to the uppercase canonical form used across
  the system. Accepts any value that converts to a string.
  """

  def normalize_carrier_code(carrier_code) do
    carrier_code
    |> to_string()
    |> String.upcase()
    |> String.trim()
  end

  @doc """
  Builds the full tracking URL for a given carrier and tracking number.
  """
  def tracking_url(carrier_code, tracking_number)
      when is_binary(carrier_code) and is_binary(tracking_number) do
    normalized = normalize_carrier_code(carrier_code)

    case Map.fetch(@carriers, normalized) do
      {:ok, base_url} -> {:ok, "#{base_url}#{URI.encode(tracking_number)}"}
      :error -> {:error, :unknown_carrier}
    end
  end

  @doc """
  Returns a human-readable label for a tracking status code.
  """
  def status_label(status_code) when is_binary(status_code) do
    Map.get(@status_labels, String.upcase(status_code), "Unknown Status")
  end

  @doc """
  Determines whether a shipment is considered active based on its status.
  """
  def active_shipment?(status_code) when is_binary(status_code) do
    status_code
    |> String.upcase()
    |> then(&(&1 in ["IN_TRANSIT", "OUT_FOR_DELIVERY", "PENDING"]))
  end

  @doc """
  Formats a tracking event for the activity log.
  """
  def format_event(%{
        status: status,
        location: location,
        timestamp: %DateTime{} = ts
      }) do
    label = status_label(status)
    time_str = Calendar.strftime(ts, "%d/%m/%Y %H:%M")
    "[#{time_str}] #{label} — #{location}"
  end

  @doc """
  Groups a list of tracking events by calendar date.
  """
  def group_events_by_date(events) when is_list(events) do
    events
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.group_by(fn %{timestamp: ts} ->
      DateTime.to_date(ts)
    end)
  end

  @doc """
  Returns the most recent event from a list of tracking events.
  """
  def latest_event([]), do: {:error, :no_events}

  def latest_event(events) when is_list(events) do
    latest =
      Enum.max_by(events, fn %{timestamp: ts} ->
        DateTime.to_unix(ts)
      end)

    {:ok, latest}
  end

  @doc """
  Validates that a tracking number matches the expected format for a carrier.
  """
  def valid_tracking_number?("FEDEX", number) when is_binary(number),
    do: Regex.match?(~r/^\d{12,15}$/, number)

  def valid_tracking_number?("UPS", number) when is_binary(number),
    do: Regex.match?(~r/^1Z[A-Z0-9]{16}$/, number)

  def valid_tracking_number?("DHL", number) when is_binary(number),
    do: Regex.match?(~r/^\d{10,11}$/, number)

  def valid_tracking_number?("CORREIOS", number) when is_binary(number),
    do: Regex.match?(~r/^[A-Z]{2}\d{9}[A-Z]{2}$/, number)

  def valid_tracking_number?(_, _), do: false
end
```
