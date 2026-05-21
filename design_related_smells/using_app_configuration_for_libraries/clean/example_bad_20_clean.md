```elixir
defmodule InvoiceFormatter do
  @moduledoc """
  Library for formatting invoice data into human-readable strings.
  Used across billing, reporting, and PDF generation pipelines.
  """

  alias InvoiceFormatter.LineItem

  defstruct [:id, :issued_at, :due_at, :customer_name, :line_items, :notes]

  @type t :: %__MODULE__{
          id: String.t(),
          issued_at: Date.t(),
          due_at: Date.t(),
          customer_name: String.t(),
          line_items: [LineItem.t()],
          notes: String.t() | nil
        }

  defmodule LineItem do
    @moduledoc "Represents a single billable line on an invoice."
    defstruct [:description, :quantity, :unit_price]

    @type t :: %__MODULE__{
            description: String.t(),
            quantity: non_neg_integer(),
            unit_price: float()
          }
  end

  @doc """
  Renders a complete invoice as a plain-text string suitable for
  embedding in emails or exporting to TXT files.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = invoice) do
    header = render_header(invoice)
    items = Enum.map(invoice.line_items, &format_line_item/1)
    total = calculate_total(invoice.line_items)

    lines =
      [header, "", "Items:"] ++
        Enum.map(items, fn item -> "  - #{item}" end) ++
        [
          "",
          "Total: #{format_amount(total)}",
          invoice.notes && "Notes: #{invoice.notes}" || ""
        ]

    Enum.join(lines, "\n")
  end

  @doc "Renders the invoice header block."
  @spec render_header(t()) :: String.t()
  def render_header(%__MODULE__{} = invoice) do
    """
    Invoice ##{invoice.id}
    Customer: #{invoice.customer_name}
    Issued:   #{Date.to_string(invoice.issued_at)}
    Due:      #{Date.to_string(invoice.due_at)}
    """
  end

  @doc """
  Formats a single line item as a descriptive string including
  quantity, unit price, and computed subtotal.
  """
  @spec format_line_item(LineItem.t()) :: String.t()
  def format_line_item(%LineItem{} = item) do
    subtotal = item.quantity * item.unit_price
    decimal_places = Application.fetch_env!(:invoice_formatter, :decimal_places)
    currency_symbol = Application.fetch_env!(:invoice_formatter, :currency_symbol)

    unit_str = :erlang.float_to_binary(item.unit_price, decimals: decimal_places)
    sub_str = :erlang.float_to_binary(subtotal, decimals: decimal_places)

    "#{item.description} x#{item.quantity} @ #{currency_symbol}#{unit_str} = #{currency_symbol}#{sub_str}"
  end

  @doc """
  Formats a raw float amount using the configured currency symbol
  and decimal precision from the application environment.
  """
  @spec format_amount(float()) :: String.t()
  def format_amount(amount) when is_float(amount) do
    decimal_places = Application.fetch_env!(:invoice_formatter, :decimal_places)
    currency_symbol = Application.fetch_env!(:invoice_formatter, :currency_symbol)
    formatted = :erlang.float_to_binary(amount, decimals: decimal_places)
    "#{currency_symbol}#{formatted}"
  end

  @doc "Calculates the total amount from a list of line items."
  @spec calculate_total([LineItem.t()]) :: float()
  def calculate_total(line_items) when is_list(line_items) do
    Enum.reduce(line_items, 0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)
  end

  @doc "Returns true if the invoice is overdue based on today's date."
  @spec overdue?(t()) :: boolean()
  def overdue?(%__MODULE__{due_at: due_at}) do
    Date.compare(Date.utc_today(), due_at) == :gt
  end

  @doc "Summarises the invoice into a short one-line description."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = invoice) do
    total = calculate_total(invoice.line_items)
    status = if overdue?(invoice), do: "OVERDUE", else: "pending"
    "Invoice ##{invoice.id} for #{invoice.customer_name} — #{format_amount(total)} [#{status}]"
  end
end
```
