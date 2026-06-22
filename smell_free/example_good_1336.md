```elixir
defmodule Billing.InvoiceGenerator do
  @moduledoc """
  Generates PDF invoice documents from structured invoice data.

  HTML rendering is separated from PDF conversion, allowing the HTML template
  to be previewed in a browser without a PDF engine dependency.
  The PDF engine adapter is supplied per-call for testability.
  """

  alias Billing.InvoiceGenerator.{InvoiceData, HtmlRenderer, PdfAdapter, GeneratedInvoice}

  @doc """
  Generates a PDF invoice binary from a structured `InvoiceData` struct.

  Returns `{:ok, generated_invoice}` with the binary and metadata, or an error.
  """
  @spec generate(InvoiceData.t(), keyword()) ::
          {:ok, GeneratedInvoice.t()} | {:error, String.t()}
  def generate(%InvoiceData{} = data, opts \\ []) do
    adapter = Keyword.get(opts, :pdf_adapter, PdfAdapter.default())
    locale = Keyword.get(opts, :locale, "en")

    with {:ok, html} <- HtmlRenderer.render(data, locale),
         {:ok, pdf_binary} <- PdfAdapter.convert(adapter, html),
         {:ok, invoice} <- GeneratedInvoice.build(data, pdf_binary) do
      {:ok, invoice}
    end
  end

  @doc """
  Renders invoice data to HTML without converting to PDF.
  """
  @spec render_html(InvoiceData.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render_html(%InvoiceData{} = data, locale \\ "en") do
    HtmlRenderer.render(data, locale)
  end
end

defmodule Billing.InvoiceGenerator.InvoiceData do
  @moduledoc "Typed value object carrying all data needed to render an invoice."

  @enforce_keys [:number, :issued_on, :due_on, :vendor, :customer, :line_items, :currency]
  defstruct [:number, :issued_on, :due_on, :vendor, :customer, :line_items, :currency,
             :notes, tax_rate_pct: 0]

  @type party :: %{name: String.t(), address: String.t()}
  @type line_item :: %{description: String.t(), quantity: pos_integer(), unit_price_cents: pos_integer()}

  @type t :: %__MODULE__{
          number: String.t(),
          issued_on: Date.t(),
          due_on: Date.t(),
          vendor: party(),
          customer: party(),
          line_items: [line_item()],
          currency: String.t(),
          notes: String.t() | nil,
          tax_rate_pct: non_neg_integer()
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{number: n, issued_on: io, due_on: do_, vendor: v, customer: c,
                  line_items: li, currency: cur} = m)
      when is_binary(n) and is_binary(cur) and is_list(li) and li != [] do
    {:ok, %__MODULE__{
      number: n, issued_on: io, due_on: do_, vendor: v, customer: c,
      line_items: li, currency: cur,
      notes: Map.get(m, :notes),
      tax_rate_pct: Map.get(m, :tax_rate_pct, 0)
    }}
  end

  def from_map(_), do: {:error, "invalid invoice data"}

  @spec subtotal_cents(t()) :: non_neg_integer()
  def subtotal_cents(%__MODULE__{line_items: items}) do
    Enum.sum(Enum.map(items, fn i -> i.quantity * i.unit_price_cents end))
  end

  @spec tax_cents(t()) :: non_neg_integer()
  def tax_cents(%__MODULE__{tax_rate_pct: rate} = data) do
    round(subtotal_cents(data) * rate / 100)
  end

  @spec total_cents(t()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = data), do: subtotal_cents(data) + tax_cents(data)
end

defmodule Billing.InvoiceGenerator.HtmlRenderer do
  @moduledoc "Renders invoice HTML from structured data using EEx templates."

  alias Billing.InvoiceGenerator.InvoiceData

  @template_dir Application.app_dir(:billing, "priv/templates/invoices")

  @spec render(InvoiceData.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render(%InvoiceData{} = data, locale) when is_binary(locale) do
    template_path = Path.join(@template_dir, "invoice_#{locale}.html.eex")

    assigns = [
      data: data,
      subtotal: InvoiceData.subtotal_cents(data),
      tax: InvoiceData.tax_cents(data),
      total: InvoiceData.total_cents(data)
    ]

    html = EEx.eval_file(template_path, assigns)
    {:ok, html}
  rescue
    err -> {:error, "HTML render failed: #{Exception.message(err)}"}
  end
end

defmodule Billing.InvoiceGenerator.GeneratedInvoice do
  @moduledoc false

  alias Billing.InvoiceGenerator.InvoiceData

  @enforce_keys [:invoice_number, :pdf_binary, :byte_size, :generated_at]
  defstruct [:invoice_number, :pdf_binary, :byte_size, :generated_at]

  @type t :: %__MODULE__{}

  @spec build(InvoiceData.t(), binary()) :: {:ok, t()} | {:error, String.t()}
  def build(%InvoiceData{number: num}, pdf_binary) when is_binary(pdf_binary) do
    {:ok, %__MODULE__{
      invoice_number: num,
      pdf_binary: pdf_binary,
      byte_size: byte_size(pdf_binary),
      generated_at: DateTime.utc_now()
    }}
  end

  def build(_, _), do: {:error, "invalid PDF binary"}
end

defmodule Billing.InvoiceGenerator.PdfAdapter do
  @moduledoc "Behaviour for HTML-to-PDF conversion adapters."

  @callback convert(String.t()) :: {:ok, binary()} | {:error, String.t()}

  @spec convert(module(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def convert(adapter_module, html) when is_atom(adapter_module) and is_binary(html) do
    adapter_module.convert(html)
  end

  @spec default() :: module()
  def default, do: Application.get_env(:billing, :pdf_adapter, Billing.InvoiceGenerator.Adapters.Chromic)
end
```
