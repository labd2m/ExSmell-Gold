**File:** `example_good_1312.md`

```elixir
defmodule Invoicing.LineItem do
  @moduledoc "A single charge line on an invoice."

  @enforce_keys [:description, :quantity, :unit_amount_cents, :currency]
  defstruct [:description, :quantity, :unit_amount_cents, :currency]

  @type t :: %__MODULE__{
          description: String.t(),
          quantity: pos_integer(),
          unit_amount_cents: pos_integer(),
          currency: String.t()
        }

  @spec total_cents(t()) :: pos_integer()
  def total_cents(%__MODULE__{quantity: qty, unit_amount_cents: unit}), do: qty * unit
end

defmodule Invoicing.Invoice do
  @moduledoc "Represents a generated invoice for a billing period."

  @enforce_keys [:id, :customer_id, :line_items, :currency, :period_start, :period_end, :issued_at]
  defstruct [
    :id,
    :customer_id,
    :line_items,
    :currency,
    :period_start,
    :period_end,
    :issued_at,
    :due_at,
    :paid_at,
    status: :draft
  ]

  @type status :: :draft | :open | :paid | :void
  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          line_items: [Invoicing.LineItem.t()],
          currency: String.t(),
          period_start: Date.t(),
          period_end: Date.t(),
          issued_at: DateTime.t(),
          due_at: DateTime.t() | nil,
          paid_at: DateTime.t() | nil,
          status: status()
        }

  @spec subtotal_cents(t()) :: non_neg_integer()
  def subtotal_cents(%__MODULE__{line_items: items}) do
    Enum.sum(Enum.map(items, &Invoicing.LineItem.total_cents/1))
  end

  @spec finalize(t()) :: {:ok, t()} | {:error, :empty_invoice}
  def finalize(%__MODULE__{line_items: []}), do: {:error, :empty_invoice}

  def finalize(%__MODULE__{} = invoice) do
    due_at = DateTime.add(invoice.issued_at, 30, :day)
    {:ok, %{invoice | status: :open, due_at: due_at}}
  end

  @spec mark_paid(t(), DateTime.t()) :: {:ok, t()} | {:error, :already_paid | :not_open}
  def mark_paid(%__MODULE__{status: :paid}, _paid_at), do: {:error, :already_paid}
  def mark_paid(%__MODULE__{status: status}, _paid_at) when status != :open, do: {:error, :not_open}
  def mark_paid(%__MODULE__{} = invoice, paid_at), do: {:ok, %{invoice | status: :paid, paid_at: paid_at}}
end

defmodule Invoicing.Generator do
  @moduledoc """
  Generates invoices from a subscription and a list of metered usage records
  for a given billing period.
  """

  alias Invoicing.{Invoice, LineItem}

  @type usage_record :: %{description: String.t(), quantity: pos_integer(), unit_amount_cents: pos_integer()}
  @type subscription :: %{customer_id: String.t(), plan_amount_cents: pos_integer(), currency: String.t()}

  @spec generate(subscription(), [usage_record()], Date.t(), Date.t()) :: Invoice.t()
  def generate(subscription, usage_records, %Date{} = period_start, %Date{} = period_end) do
    base_item = build_base_line_item(subscription, period_start, period_end)
    usage_items = Enum.map(usage_records, &build_usage_line_item(&1, subscription.currency))

    %Invoice{
      id: generate_id(),
      customer_id: subscription.customer_id,
      line_items: [base_item | usage_items],
      currency: subscription.currency,
      period_start: period_start,
      period_end: period_end,
      issued_at: DateTime.utc_now()
    }
  end

  defp build_base_line_item(subscription, period_start, period_end) do
    label = "Subscription — #{Date.to_iso8601(period_start)} to #{Date.to_iso8601(period_end)}"

    %LineItem{
      description: label,
      quantity: 1,
      unit_amount_cents: subscription.plan_amount_cents,
      currency: subscription.currency
    }
  end

  defp build_usage_line_item(record, currency) do
    %LineItem{
      description: record.description,
      quantity: record.quantity,
      unit_amount_cents: record.unit_amount_cents,
      currency: currency
    }
  end

  defp generate_id do
    "inv_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end

defmodule Invoicing.Formatter do
  @moduledoc "Formats invoice data for display or export."

  alias Invoicing.{Invoice, LineItem}

  @spec to_summary(Invoice.t()) :: map()
  def to_summary(%Invoice{} = invoice) do
    %{
      id: invoice.id,
      customer_id: invoice.customer_id,
      status: invoice.status,
      currency: invoice.currency,
      subtotal: format_amount(Invoice.subtotal_cents(invoice), invoice.currency),
      period: "#{invoice.period_start} – #{invoice.period_end}",
      issued_at: DateTime.to_iso8601(invoice.issued_at),
      due_at: if(invoice.due_at, do: DateTime.to_iso8601(invoice.due_at)),
      line_items: Enum.map(invoice.line_items, &format_line_item/1)
    }
  end

  defp format_line_item(%LineItem{} = item) do
    %{
      description: item.description,
      quantity: item.quantity,
      unit_amount: format_amount(item.unit_amount_cents, item.currency),
      total: format_amount(LineItem.total_cents(item), item.currency)
    }
  end

  defp format_amount(cents, currency) do
    units = div(cents, 100)
    remainder = rem(cents, 100)
    "#{currency} #{units}.#{String.pad_leading(to_string(remainder), 2, "0")}"
  end
end
```
