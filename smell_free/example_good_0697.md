```elixir
defmodule Billing.InvoiceRenderer do
  @moduledoc """
  Renders invoice data into formatted output strings for PDF generation
  and email delivery. Implements the `Reports.Exportable` behaviour so
  it integrates with the platform export pipeline. Output is UTF-8
  HTML with inline styles for email client compatibility.
  """

  @behaviour Reports.Exportable

  alias Billing.InvoiceContext
  alias Finance.Money

  @company_name "MyApp Inc."
  @company_address "123 Main Street, San Francisco, CA 94105"

  @impl Reports.Exportable
  def gather_data(%{invoice_id: invoice_id}) when is_binary(invoice_id) do
    case InvoiceContext.fetch_invoice(invoice_id) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def gather_data(_params), do: {:error, :not_found}

  @impl Reports.Exportable
  def render_html(invoice) do
    html = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8"><title>Invoice #{invoice.id}</title></head>
    <body style="font-family: sans-serif; color: #333; max-width: 700px; margin: 0 auto;">
      <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
          <td><h1 style="margin:0">Invoice</h1></td>
          <td style="text-align:right">
            <strong>#{@company_name}</strong><br>
            #{@company_address}
          </td>
        </tr>
      </table>
      <hr style="border: 1px solid #eee; margin: 24px 0;">
      <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
          <td><strong>Invoice #</strong></td>
          <td>#{invoice.id}</td>
          <td><strong>Date</strong></td>
          <td>#{Date.to_iso8601(Date.utc_today())}</td>
        </tr>
        <tr>
          <td><strong>Due</strong></td>
          <td>#{Date.to_iso8601(invoice.due_on)}</td>
          <td><strong>Status</strong></td>
          <td style="text-transform: capitalize;">#{invoice.status}</td>
        </tr>
      </table>
      <h3 style="margin-top: 32px;">Line Items</h3>
      <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse: collapse;">
        <thead>
          <tr style="background:#f5f5f5">
            <th style="text-align:left; border-bottom:2px solid #ddd">Description</th>
            <th style="text-align:right; border-bottom:2px solid #ddd">Amount</th>
          </tr>
        </thead>
        <tbody>
          #{render_line_items(invoice.line_items, invoice.currency)}
        </tbody>
        <tfoot>
          <tr>
            <td style="text-align:right; padding:16px 8px;"><strong>Total</strong></td>
            <td style="text-align:right; padding:16px 8px;"><strong>#{format_amount(invoice_total(invoice), invoice.currency)}</strong></td>
          </tr>
        </tfoot>
      </table>
    </body>
    </html>
    """

    {:ok, html}
  end

  @impl Reports.Exportable
  def filename(%{invoice_id: id}), do: "invoice_#{id}.pdf"
  def filename(_), do: "invoice.pdf"

  defp render_line_items(items, currency) when is_list(items) do
    Enum.map_join(items, "
", fn item ->
      amount = format_amount(item.amount_cents, currency)
      """
      <tr>
        <td style="border-bottom:1px solid #eee; padding:8px;">#{item.description}</td>
        <td style="border-bottom:1px solid #eee; padding:8px; text-align:right;">#{amount}</td>
      </tr>
      """
    end)
  end

  defp invoice_total(%{line_items: items}) when is_list(items) do
    Enum.sum_by(items, & &1.amount_cents)
  end

  defp format_amount(cents, currency) when is_integer(cents) do
    major = div(cents, 100)
    minor = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{major}.#{minor} #{currency}"
  end
end
```
