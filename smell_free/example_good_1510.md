```elixir
defprotocol Reports.Serializable do
  @moduledoc """
  Protocol for converting domain report structs into exportable
  representations. Implementations must support both JSON-compatible
  maps and CSV-friendly row lists.
  """

  @doc "Returns a flat map suitable for JSON serialization."
  @spec to_export_map(t()) :: map()
  def to_export_map(report)

  @doc "Returns a list of string row values for CSV export."
  @spec to_csv_row(t()) :: [String.t()]
  def to_csv_row(report)
end

defmodule Reports.SalesReport do
  @moduledoc """
  Struct representing an aggregated sales report for a given period.
  """

  @enforce_keys [:period, :total_revenue_cents, :order_count, :currency]

  defstruct [:period, :total_revenue_cents, :order_count, :currency, :top_sku]

  @type t :: %__MODULE__{
          period: Date.Range.t(),
          total_revenue_cents: non_neg_integer(),
          order_count: non_neg_integer(),
          currency: String.t(),
          top_sku: String.t() | nil
        }
end

defimpl Reports.Serializable, for: Reports.SalesReport do
  @moduledoc """
  Serialization for `SalesReport` structs.
  """

  def to_export_map(%Reports.SalesReport{} = report) do
    %{
      period_start: Date.to_iso8601(report.period.first),
      period_end: Date.to_iso8601(report.period.last),
      total_revenue_cents: report.total_revenue_cents,
      order_count: report.order_count,
      currency: report.currency,
      top_sku: report.top_sku || ""
    }
  end

  def to_csv_row(%Reports.SalesReport{} = report) do
    [
      Date.to_iso8601(report.period.first),
      Date.to_iso8601(report.period.last),
      Integer.to_string(report.total_revenue_cents),
      Integer.to_string(report.order_count),
      report.currency,
      report.top_sku || ""
    ]
  end
end

defmodule Reports.Exporter do
  @moduledoc """
  Exports a list of serializable reports to a chosen format.

  Accepts any struct that implements the `Reports.Serializable` protocol,
  making it straightforward to add new report types without modifying
  export logic.
  """

  alias Reports.Serializable

  @type format :: :json | :csv
  @type export_result :: {:ok, binary()} | {:error, :unsupported_format | :encoding_failed}

  @csv_separator ","
  @newline "\n"

  @doc """
  Exports a list of reports as a binary in the specified format.
  """
  @spec export([Serializable.t()], format()) :: export_result()
  def export(reports, :json) when is_list(reports) do
    rows = Enum.map(reports, &Serializable.to_export_map/1)

    case Jason.encode(rows) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :encoding_failed}
    end
  end

  def export(reports, :csv) when is_list(reports) do
    rows =
      reports
      |> Enum.map(&Serializable.to_csv_row/1)
      |> Enum.map(&Enum.join(&1, @csv_separator))
      |> Enum.join(@newline)

    {:ok, rows}
  end

  def export(_reports, _format), do: {:error, :unsupported_format}
end
```
