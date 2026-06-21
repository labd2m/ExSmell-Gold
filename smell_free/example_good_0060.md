```elixir
defprotocol Reports.Formatter do
  @moduledoc """
  Protocol for rendering domain report structs into formatted output strings.
  Each implementation defines how a specific report type is presented in a
  given output format such as plain text or CSV.
  """

  @doc "Renders the report as a formatted string."
  @spec render(t()) :: String.t()
  def render(report)

  @doc "Returns the MIME type of the output produced by `render/1`."
  @spec mime_type(t()) :: String.t()
  def mime_type(report)
end

defmodule Reports.SalesSummary do
  @moduledoc "Structured summary of sales performance over a reporting period."

  @enforce_keys [:period_label, :total_revenue_cents, :order_count, :top_products]
  defstruct [:period_label, :total_revenue_cents, :order_count, :top_products]

  @type product_entry :: %{
          name: String.t(),
          units_sold: non_neg_integer(),
          revenue_cents: non_neg_integer()
        }

  @type t :: %__MODULE__{
          period_label: String.t(),
          total_revenue_cents: non_neg_integer(),
          order_count: non_neg_integer(),
          top_products: [product_entry()]
        }
end

defimpl Reports.Formatter, for: Reports.SalesSummary do
  @moduledoc "Plain-text renderer for SalesSummary reports."

  def render(%Reports.SalesSummary{} = report) do
    header = "Sales Report: #{report.period_label}"
    divider = String.duplicate("─", String.length(header))
    revenue = format_currency(report.total_revenue_cents)

    product_lines =
      report.top_products
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        "  #{i}. #{p.name} — #{p.units_sold} units — #{format_currency(p.revenue_cents)}"
      end)

    [header, divider, "Total Revenue : #{revenue}", "Order Count   : #{report.order_count}",
     "", "Top Products:", product_lines]
    |> List.flatten()
    |> Enum.join("\n")
  end

  def mime_type(_), do: "text/plain"

  defp format_currency(cents) do
    "$#{div(cents, 100)}.#{String.pad_leading(to_string(rem(cents, 100)), 2, "0")}"
  end
end

defmodule Reports.SalesSummary.CSVFormatter do
  @moduledoc "CSV renderer for SalesSummary reports, suitable for spreadsheet import."

  defimpl Reports.Formatter, for: Reports.SalesSummary do
    @header "rank,product_name,units_sold,revenue_usd"

    def render(%Reports.SalesSummary{} = report) do
      rows =
        report.top_products
        |> Enum.with_index(1)
        |> Enum.map(fn {p, i} ->
          revenue = Float.round(p.revenue_cents / 100, 2)
          "#{i},\"#{escape_csv(p.name)}\",#{p.units_sold},#{revenue}"
        end)

      Enum.join([@header | rows], "\n")
    end

    def mime_type(_), do: "text/csv"

    defp escape_csv(str), do: String.replace(str, "\"", "\"\"\"")
  end
end

defmodule Reports.Renderer do
  @moduledoc """
  Renders a report struct to a string and MIME type using the appropriate
  protocol implementation. Accepts any struct implementing `Reports.Formatter`.
  """

  @doc "Renders the given report, returning content and MIME type."
  @spec render(Reports.Formatter.t()) :: %{content: String.t(), mime_type: String.t()}
  def render(report) do
    %{
      content: Reports.Formatter.render(report),
      mime_type: Reports.Formatter.mime_type(report)
    }
  end
end
```
