```elixir
defmodule Logistics.ShipmentExporter do
  @moduledoc """
  Exports shipment records to CSV for carrier billing reconciliation
  and internal reporting. Each row corresponds to one shipment leg.
  """

  alias Logistics.{Shipment, Address}

  @csv_headers ~w[
    tracking_number
    carrier
    service_level
    origin_postal_code
    destination_postal_code
    weight_kg
    declared_value
    status
    dispatched_at
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Converts a list of shipments into a CSV binary string.
  Returns `{:ok, csv}` or `{:error, reason}`.
  """
  def export(shipments) when is_list(shipments) do
    rows =
      shipments
      |> Stream.map(&build_row/1)
      |> Stream.map(&encode_row/1)
      |> Enum.to_list()

    csv = Enum.join([@csv_headers |> Enum.join(",") | rows], "\n")
    {:ok, csv}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Builds the ordered list of cell values for one shipment record.
  """
  def build_row(%Shipment{} = shipment) do
    [
      shipment.tracking_number,
      shipment.carrier,
      shipment.service_level,
      shipment.origin.postal_code,
      shipment.destination.postal_code,
      shipment.weight_kg,
      shipment.declared_value,
      shipment.status,
      shipment.dispatched_at
    ]
  end

  @doc """
  Encodes a single row (list of field values) into a CSV line string.
  """
  def encode_row(fields) when is_list(fields) do
    fields
    |> Enum.map(&serialize_field/1)
    |> Enum.join(",")
  end

  @doc """
  Serializes a single field value to a CSV-safe string.
  Wraps the value in double-quotes and escapes internal quotes.
  """
  def serialize_field(value) do
    str = to_string(value)
    escaped = String.replace(str, "\"", "\"\"")
    "\"#{escaped}\""
  end

  # ---------------------------------------------------------------------------
  # Shipment filtering helpers
  # ---------------------------------------------------------------------------

  @doc "Filters shipments dispatched within the given date range."
  def filter_by_date_range(shipments, %Date{} = from, %Date{} = to) do
    Enum.filter(shipments, fn s ->
      date = DateTime.to_date(s.dispatched_at)
      Date.compare(date, from) in [:gt, :eq] and
        Date.compare(date, to) in [:lt, :eq]
    end)
  end

  @doc "Filters shipments by carrier name (case-insensitive)."
  def filter_by_carrier(shipments, carrier) when is_binary(carrier) do
    normalized = String.downcase(carrier)

    Enum.filter(shipments, fn s ->
      String.downcase(s.carrier) == normalized
    end)
  end

  @doc "Returns the total declared value across a list of shipments."
  def total_declared_value(shipments) do
    Enum.reduce(shipments, Decimal.new(0), fn s, acc ->
      Decimal.add(acc, s.declared_value)
    end)
  end

  @doc "Groups shipments by their current status atom."
  def group_by_status(shipments) do
    Enum.group_by(shipments, & &1.status)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_shipment(%Shipment{tracking_number: tn}) when is_binary(tn) and tn != "",
    do: :ok

  defp validate_shipment(_), do: {:error, :invalid_tracking_number}
end
```
