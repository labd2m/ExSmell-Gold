```elixir
defprotocol Reports.Renderable do
  @moduledoc """
  Protocol for converting domain summary structs into renderable report documents.
  """

  @spec to_report(t()) :: Reports.Document.t()
  def to_report(value)
end

defmodule Reports.Document do
  @moduledoc """
  An immutable, structured report ready for rendering to text, HTML, or JSON.
  """

  @enforce_keys [:title, :sections, :generated_at]
  defstruct [:title, :sections, :generated_at, :metadata]

  @type section :: %{heading: String.t(), rows: list(%{label: String.t(), value: String.t()})}

  @type t :: %__MODULE__{
          title: String.t(),
          sections: list(section()),
          generated_at: DateTime.t(),
          metadata: map() | nil
        }

  @spec new(String.t(), list(section())) :: t()
  def new(title, sections) when is_binary(title) and is_list(sections) do
    %__MODULE__{title: title, sections: sections, generated_at: DateTime.utc_now()}
  end
end

defmodule Reports.SalesSummary do
  @enforce_keys [:period, :revenue_cents, :order_count]
  defstruct [:period, :revenue_cents, :order_count, :refunds_cents, :top_products]

  @type t :: %__MODULE__{
          period: String.t(),
          revenue_cents: integer(),
          order_count: non_neg_integer(),
          refunds_cents: integer() | nil,
          top_products: list(%{name: String.t(), revenue_cents: integer()}) | nil
        }
end

defimpl Reports.Renderable, for: Reports.SalesSummary do
  alias Reports.Document

  def to_report(%Reports.SalesSummary{} = s) do
    Document.new("Sales Summary — #{s.period}", build_sections(s))
  end

  defp build_sections(s) do
    [summary_section(s) | maybe_products_section(s)]
  end

  defp summary_section(s) do
    %{
      heading: "Overview",
      rows: [
        %{label: "Gross Revenue", value: format_cents(s.revenue_cents)},
        %{label: "Total Orders", value: Integer.to_string(s.order_count)},
        %{label: "Refunds", value: format_cents(s.refunds_cents || 0)}
      ]
    }
  end

  defp maybe_products_section(%{top_products: nil}), do: []
  defp maybe_products_section(%{top_products: []}), do: []

  defp maybe_products_section(%{top_products: products}) do
    rows = Enum.map(products, fn p -> %{label: p.name, value: format_cents(p.revenue_cents)} end)
    [%{heading: "Top Products", rows: rows}]
  end

  defp format_cents(cents) do
    dollars = div(cents, 100)
    cents_part = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{cents_part}"
  end
end

defmodule Reports.Renderer do
  @moduledoc """
  Renders a `Reports.Document` into plain text or a structured map.
  """

  alias Reports.Document

  @spec to_text(Document.t()) :: String.t()
  def to_text(%Document{title: title, sections: sections, generated_at: ts}) do
    separator = String.duplicate("-", 60)

    header = "#{title}\nGenerated: #{DateTime.to_string(ts)}\n#{separator}\n"
    body = Enum.map_join(sections, "\n\n", &render_section/1)

    header <> body
  end

  @spec to_map(Document.t()) :: map()
  def to_map(%Document{} = doc) do
    %{
      title: doc.title,
      generated_at: DateTime.to_iso8601(doc.generated_at),
      sections: doc.sections
    }
  end

  defp render_section(%{heading: heading, rows: rows}) do
    row_text = Enum.map_join(rows, "\n", fn %{label: l, value: v} -> "  #{l}: #{v}" end)
    "#{heading}\n#{row_text}"
  end
end
```
