# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `InvoiceFormatter` module — entire GenServer structure |
| **Affected function(s)** | `format_line_items/2`, `format_summary/2`, `format_header/2`, `render_pdf_payload/2` |
| **Short explanation** | Formatting invoice data into strings and maps is a pure transformation — it depends only on its input data and formatting rules. No state needs to persist between calls, no shared resource is accessed, and no concurrency benefit exists. A GenServer here is only a structural choice, not a runtime necessity. |

```elixir
defmodule Billing.InvoiceFormatter do
  use GenServer

  @moduledoc """
  Transforms raw invoice data structures into formatted representations
  suitable for PDF rendering, email bodies, and API responses.
  Called by the invoicing pipeline after an invoice is finalised.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because all formatting operations are pure
  # data transformations with no side effects. The GenServer holds no meaningful
  # state (only an empty map), and every request could safely run in the calling
  # process. Routing concurrent invoice-formatting requests through a single
  # process creates a serial queue where parallelism would be trivially possible.

  @date_format "{D} {Mshort} {YYYY}"
  @currency_symbols %{USD: "$", EUR: "€", GBP: "£", BRL: "R$", JPY: "¥"}

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc "Returns a list of formatted line-item maps ready for template rendering."
  def format_line_items(pid, invoice) do
    GenServer.call(pid, {:format_line_items, invoice})
  end

  @doc "Returns a summary map with subtotal, tax, discount, and total strings."
  def format_summary(pid, invoice) do
    GenServer.call(pid, {:format_summary, invoice})
  end

  @doc "Returns a header map with client details, invoice number, and dates."
  def format_header(pid, invoice) do
    GenServer.call(pid, {:format_header, invoice})
  end

  @doc "Returns the complete payload map expected by the PDF rendering service."
  def render_pdf_payload(pid, invoice) do
    GenServer.call(pid, {:render_pdf_payload, invoice})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:format_line_items, invoice}, _from, state) do
    symbol = Map.get(@currency_symbols, invoice.currency, "")

    items =
      Enum.with_index(invoice.line_items, 1)
      |> Enum.map(fn {item, idx} ->
        %{
          index:       idx,
          description: item.description,
          quantity:    item.quantity,
          unit_price:  "#{symbol}#{:erlang.float_to_binary(item.unit_price / 1, decimals: 2)}",
          total:       "#{symbol}#{:erlang.float_to_binary(item.quantity * item.unit_price / 1, decimals: 2)}"
        }
      end)

    {:reply, {:ok, items}, state}
  end

  def handle_call({:format_summary, invoice}, _from, state) do
    symbol   = Map.get(@currency_symbols, invoice.currency, "")
    subtotal = Enum.reduce(invoice.line_items, 0.0, fn i, acc -> acc + i.quantity * i.unit_price end)
    tax      = subtotal * invoice.tax_rate
    discount = subtotal * Map.get(invoice, :discount_rate, 0.0)
    total    = subtotal + tax - discount

    fmt = fn v -> "#{symbol}#{:erlang.float_to_binary(v / 1, decimals: 2)}" end

    summary = %{
      subtotal: fmt.(subtotal),
      tax:      fmt.(tax),
      discount: fmt.(discount),
      total:    fmt.(total),
      tax_rate: "#{trunc(invoice.tax_rate * 100)}%"
    }

    {:reply, {:ok, summary}, state}
  end

  def handle_call({:format_header, invoice}, _from, state) do
    header = %{
      invoice_number: invoice.number,
      issued_on:      Calendar.strftime(invoice.issued_on, @date_format),
      due_on:         Calendar.strftime(invoice.due_on, @date_format),
      client_name:    invoice.client.name,
      client_email:   invoice.client.email,
      client_address: Enum.join(invoice.client.address_lines, "\n"),
      vendor_name:    invoice.vendor.name,
      vendor_address: Enum.join(invoice.vendor.address_lines, "\n")
    }

    {:reply, {:ok, header}, state}
  end

  def handle_call({:render_pdf_payload, invoice}, _from, state) do
    symbol   = Map.get(@currency_symbols, invoice.currency, "")
    subtotal = Enum.reduce(invoice.line_items, 0.0, fn i, acc -> acc + i.quantity * i.unit_price end)
    tax      = subtotal * invoice.tax_rate
    total    = subtotal + tax

    payload = %{
      meta: %{
        number:    invoice.number,
        issued_on: Calendar.strftime(invoice.issued_on, @date_format),
        due_on:    Calendar.strftime(invoice.due_on, @date_format)
      },
      parties: %{
        client: invoice.client,
        vendor: invoice.vendor
      },
      lines: Enum.map(invoice.line_items, fn item ->
        %{
          description: item.description,
          qty:         item.quantity,
          price:       "#{symbol}#{:erlang.float_to_binary(item.unit_price / 1, decimals: 2)}",
          amount:      "#{symbol}#{:erlang.float_to_binary(item.quantity * item.unit_price / 1, decimals: 2)}"
        }
      end),
      totals: %{
        subtotal: "#{symbol}#{:erlang.float_to_binary(subtotal / 1, decimals: 2)}",
        tax:      "#{symbol}#{:erlang.float_to_binary(tax / 1, decimals: 2)}",
        total:    "#{symbol}#{:erlang.float_to_binary(total / 1, decimals: 2)}"
      }
    }

    {:reply, {:ok, payload}, state}
  end

  # VALIDATION: SMELL END
end
```
