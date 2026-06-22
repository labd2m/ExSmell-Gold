```elixir
defprotocol Reporting.Exportable do
  @moduledoc """
  Protocol for domain entities that can be serialized into exportable report formats.
  Implement this protocol to enable CSV and JSON export for any data type.
  """

  @doc "Returns a list of column headers for tabular exports."
  @spec headers(t()) :: [String.t()]
  def headers(value)

  @doc "Returns an ordered list of string values matching the headers."
  @spec to_row(t()) :: [String.t()]
  def to_row(value)

  @doc "Returns a key-value map suitable for JSON serialization."
  @spec to_map(t()) :: map()
  def to_map(value)
end

defmodule Reporting.SalesRecord do
  @moduledoc """
  Represents a single sales transaction for reporting purposes.
  """

  @type t :: %__MODULE__{
    order_id: String.t(),
    product_name: String.t(),
    quantity: pos_integer(),
    unit_price_cents: pos_integer(),
    sold_at: DateTime.t()
  }

  defstruct [:order_id, :product_name, :quantity, :unit_price_cents, :sold_at]

  defimpl Reporting.Exportable do
    def headers(_), do: ["Order ID", "Product", "Quantity", "Unit Price", "Total", "Sold At"]

    def to_row(%{order_id: oid, product_name: name, quantity: qty,
                 unit_price_cents: price, sold_at: sold_at}) do
      [
        oid,
        name,
        Integer.to_string(qty),
        format_cents(price),
        format_cents(price * qty),
        DateTime.to_string(sold_at)
      ]
    end

    def to_map(%{order_id: oid, product_name: name, quantity: qty,
                 unit_price_cents: price, sold_at: sold_at}) do
      %{
        order_id: oid,
        product_name: name,
        quantity: qty,
        unit_price_cents: price,
        total_cents: price * qty,
        sold_at: DateTime.to_iso8601(sold_at)
      }
    end

    defp format_cents(cents) do
      "$#{div(cents, 100)}.#{String.pad_leading("#{rem(cents, 100)}", 2, "0")}"
    end
  end
end

defmodule Reporting.CsvExporter do
  @moduledoc """
  Exports a list of `Reporting.Exportable` values to CSV format.
  """

  alias Reporting.Exportable

  @spec export([Exportable.t()]) :: {:ok, String.t()} | {:error, :empty_dataset}
  def export([]), do: {:error, :empty_dataset}

  def export([first | _] = records) do
    header_row = first |> Exportable.headers() |> encode_row()
    data_rows = Enum.map(records, fn r -> r |> Exportable.to_row() |> encode_row() end)

    csv = ([header_row | data_rows]) |> Enum.join("\n")
    {:ok, csv}
  end

  @spec encode_row([String.t()]) :: String.t()
  defp encode_row(fields) do
    fields
    |> Enum.map(&escape_field/1)
    |> Enum.join(",")
  end

  @spec escape_field(String.t()) :: String.t()
  defp escape_field(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end

defmodule Reporting.JsonExporter do
  @moduledoc """
  Exports a list of `Reporting.Exportable` values to a JSON-compatible list of maps.
  """

  alias Reporting.Exportable

  @spec export([Exportable.t()]) :: {:ok, [map()]} | {:error, :empty_dataset}
  def export([]), do: {:error, :empty_dataset}

  def export(records) do
    maps = Enum.map(records, &Exportable.to_map/1)
    {:ok, maps}
  end
end
```
