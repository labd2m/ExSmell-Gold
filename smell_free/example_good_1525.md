```elixir
defprotocol Reporting.Serializable do
  @moduledoc """
  Protocol for converting domain structs into export-ready representations.

  Implement this protocol for any struct that participates in report generation.
  """

  @doc "Returns a flat map suitable for CSV or JSON export."
  @spec to_export_map(t()) :: map()
  def to_export_map(value)

  @doc "Returns a human-readable label used in report headers."
  @spec display_label(t()) :: String.t()
  def display_label(value)
end

defmodule Reporting.Serializable.LineItem do
  @moduledoc """
  Serialization implementation for `Commerce.Order.LineItem`.
  """

  alias Commerce.Order.LineItem

  defimpl Reporting.Serializable, for: LineItem do
    def to_export_map(%LineItem{} = item) do
      %{
        sku: item.sku,
        product_name: item.product_name,
        quantity: item.quantity,
        unit_price_cents: item.unit_price_cents,
        total_cents: item.quantity * item.unit_price_cents,
        discount_cents: item.discount_cents
      }
    end

    def display_label(%LineItem{product_name: name}), do: "Line Item: #{name}"
  end
end

defmodule Reporting.Serializable.Invoice do
  @moduledoc """
  Serialization implementation for `Commerce.Billing.Invoice`.
  """

  alias Commerce.Billing.Invoice

  defimpl Reporting.Serializable, for: Invoice do
    def to_export_map(%Invoice{} = inv) do
      %{
        invoice_number: inv.number,
        issued_at: Date.to_iso8601(inv.issued_on),
        due_at: Date.to_iso8601(inv.due_on),
        subtotal_cents: inv.subtotal_cents,
        tax_cents: inv.tax_cents,
        total_cents: inv.subtotal_cents + inv.tax_cents,
        status: Atom.to_string(inv.status)
      }
    end

    def display_label(%Invoice{number: num}), do: "Invoice ##{num}"
  end
end

defmodule Reporting.CsvExporter do
  @moduledoc """
  Exports a list of serializable structs to CSV-formatted binary.
  """

  alias Reporting.Serializable

  @doc """
  Builds a CSV string from a non-empty list of structs that implement `Serializable`.

  Column order is derived from the first record's export map keys.
  """
  @spec export([Serializable.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def export([first | _] = records) do
    row_maps = Enum.map(records, &Serializable.to_export_map/1)
    headers = first |> Serializable.to_export_map() |> Map.keys()

    header_line = headers |> Enum.map(&to_string/1) |> Enum.join(",")

    data_lines =
      Enum.map(row_maps, fn row ->
        headers |> Enum.map(&Map.fetch!(row, &1)) |> Enum.map(&to_string/1) |> Enum.join(",")
      end)

    csv = ([header_line] ++ data_lines) |> Enum.join("\n")
    {:ok, csv}
  end

  def export([]), do: {:error, "no records to export"}
end
```
