```elixir
defmodule Reporting.ExportSerializer do
  @moduledoc """
  Protocol-driven serialization layer for exporting domain reports.

  Implements a unified `Serializable` protocol dispatching to format-specific
  encoders. Consumers call `serialize/2` with any report struct and a target
  format atom; the protocol layer resolves the correct encoder transparently.
  """

  alias Reporting.Formats.{CsvEncoder, JsonEncoder}

  @type export_format :: :csv | :json
  @type serialized_output :: {:ok, binary()} | {:error, :unsupported_format} | {:error, :encoding_failed}

  defprotocol Serializable do
    @doc "Converts a domain report struct into a flat list of serializable rows."
    @spec to_rows(t()) :: [map()]
    def to_rows(report)

    @doc "Returns the ordered list of column headers for this report type."
    @spec headers(t()) :: [String.t()]
    def headers(report)
  end

  @doc """
  Serializes a report struct into the specified export format.

  The report must implement the `Serializable` protocol.
  Returns `{:ok, binary}` on success.
  """
  @spec serialize(Serializable.t(), export_format()) :: serialized_output()
  def serialize(report, :csv) do
    headers = Serializable.headers(report)
    rows = Serializable.to_rows(report)
    CsvEncoder.encode(headers, rows)
  end

  def serialize(report, :json) do
    rows = Serializable.to_rows(report)
    JsonEncoder.encode(rows)
  end

  def serialize(_report, _format), do: {:error, :unsupported_format}
end

defmodule Reporting.SalesReport do
  @moduledoc """
  Structured sales report aggregate for a given time window.

  Implements `Serializable` to support CSV and JSON exports.
  """

  @enforce_keys [:period_start, :period_end, :line_items]
  defstruct [:period_start, :period_end, :line_items]

  @type line_item :: %{
          product_name: String.t(),
          quantity: non_neg_integer(),
          unit_price_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @type t :: %__MODULE__{
          period_start: Date.t(),
          period_end: Date.t(),
          line_items: [line_item()]
        }

  defimpl Reporting.ExportSerializer.Serializable do
    def headers(_report) do
      ["Product", "Quantity", "Unit Price (cents)", "Total (cents)"]
    end

    def to_rows(%{line_items: items}) do
      Enum.map(items, fn item ->
        %{
          "Product" => item.product_name,
          "Quantity" => item.quantity,
          "Unit Price (cents)" => item.unit_price_cents,
          "Total (cents)" => item.total_cents
        }
      end)
    end
  end
end

defmodule Reporting.Formats.JsonEncoder do
  @moduledoc false

  @spec encode([map()]) :: {:ok, binary()} | {:error, :encoding_failed}
  def encode(rows) when is_list(rows) do
    case Jason.encode(rows) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :encoding_failed}
    end
  end
end

defmodule Reporting.Formats.CsvEncoder do
  @moduledoc false

  @spec encode([String.t()], [map()]) :: {:ok, binary()} | {:error, :encoding_failed}
  def encode(headers, rows) when is_list(headers) and is_list(rows) do
    header_line = Enum.join(headers, ",")

    data_lines =
      Enum.map(rows, fn row ->
        headers
        |> Enum.map(fn h -> row |> Map.get(h, "") |> to_string() |> escape_csv_field() end)
        |> Enum.join(",")
      end)

    csv = Enum.join([header_line | data_lines], "\n")
    {:ok, csv}
  rescue
    _ -> {:error, :encoding_failed}
  end

  defp escape_csv_field(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end
end
```
