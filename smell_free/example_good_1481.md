```elixir
defmodule Billing.Invoice do
  @moduledoc """
  Domain struct and validation logic for customer invoices.
  Provides constructors and line-item computation for billing workflows.
  """

  @type line_item :: %{description: String.t(), unit_price_cents: pos_integer(), quantity: pos_integer()}
  @type t :: %__MODULE__{
    id: String.t(),
    customer_id: String.t(),
    line_items: [line_item()],
    issued_on: Date.t(),
    status: :draft | :issued | :paid | :void
  }

  defstruct [:id, :customer_id, :line_items, :issued_on, :status]

  @spec new(String.t(), String.t(), [line_item()]) :: {:ok, t()} | {:error, String.t()}
  def new(id, customer_id, line_items)
      when is_binary(id) and is_binary(customer_id) and is_list(line_items) do
    with :ok <- validate_line_items(line_items) do
      invoice = %__MODULE__{
        id: id,
        customer_id: customer_id,
        line_items: line_items,
        issued_on: Date.utc_today(),
        status: :draft
      }

      {:ok, invoice}
    end
  end

  @spec total_cents(t()) :: non_neg_integer()
  def total_cents(%__MODULE__{line_items: items}) do
    Enum.reduce(items, 0, fn item, acc ->
      acc + item.unit_price_cents * item.quantity
    end)
  end

  @spec issue(t()) :: {:ok, t()} | {:error, String.t()}
  def issue(%__MODULE__{status: :draft} = invoice) do
    {:ok, %{invoice | status: :issued}}
  end

  def issue(%__MODULE__{status: status}) do
    {:error, "Cannot issue invoice with status: #{status}"}
  end

  @spec mark_paid(t()) :: {:ok, t()} | {:error, String.t()}
  def mark_paid(%__MODULE__{status: :issued} = invoice) do
    {:ok, %{invoice | status: :paid}}
  end

  def mark_paid(%__MODULE__{status: status}) do
    {:error, "Cannot mark invoice as paid with status: #{status}"}
  end

  @spec void(t()) :: {:ok, t()} | {:error, String.t()}
  def void(%__MODULE__{status: status} = invoice) when status in [:draft, :issued] do
    {:ok, %{invoice | status: :void}}
  end

  def void(%__MODULE__{status: status}) do
    {:error, "Cannot void invoice with status: #{status}"}
  end

  @spec validate_line_items([line_item()]) :: :ok | {:error, String.t()}
  defp validate_line_items([]), do: {:error, "Invoice must have at least one line item"}

  defp validate_line_items(items) do
    invalid = Enum.find(items, &invalid_line_item?/1)

    if invalid do
      {:error, "Invalid line item: #{inspect(invalid)}"}
    else
      :ok
    end
  end

  @spec invalid_line_item?(map()) :: boolean()
  defp invalid_line_item?(%{description: d, unit_price_cents: p, quantity: q})
       when is_binary(d) and is_integer(p) and p > 0 and is_integer(q) and q > 0,
       do: false

  defp invalid_line_item?(_), do: true
end

defmodule Billing.InvoiceFormatter do
  @moduledoc """
  Renders invoices into human-readable plaintext summaries for email and PDF generation.
  """

  alias Billing.Invoice

  @spec format_summary(Invoice.t()) :: String.t()
  def format_summary(%Invoice{} = invoice) do
    lines = Enum.map(invoice.line_items, &format_line_item/1)
    total = Invoice.total_cents(invoice)

    """
    Invoice ID: #{invoice.id}
    Customer:   #{invoice.customer_id}
    Issued:     #{Date.to_string(invoice.issued_on)}
    Status:     #{invoice.status}

    #{Enum.join(lines, "\n")}

    Total: #{format_cents(total)}
    """
  end

  @spec format_line_item(Invoice.line_item()) :: String.t()
  defp format_line_item(%{description: desc, unit_price_cents: price, quantity: qty}) do
    "  - #{desc} x#{qty} @ #{format_cents(price)} = #{format_cents(price * qty)}"
  end

  @spec format_cents(non_neg_integer()) :: String.t()
  defp format_cents(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading("#{remainder}", 2, "0")}"
  end
end
```
