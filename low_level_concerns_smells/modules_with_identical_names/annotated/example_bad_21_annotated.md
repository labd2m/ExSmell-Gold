# Annotated Example 21 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Module definitions at the top of each "file" block
- **Affected functions:** `Billing.Invoice.build/2`, `Billing.Invoice.total/1`, `Billing.Invoice.apply_discount/2`, `Billing.Invoice.finalize/1`
- **Short explanation:** Two separate modules are both named `Billing.Invoice`. When BEAM loads both (e.g., from two different source files in the same project), only the second definition survives in memory. Any function defined exclusively in the first module becomes permanently inaccessible, leading to silent runtime failures that are hard to trace.

---

```elixir
# ── file: lib/billing/invoice.ex ────────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because a module named `Billing.Invoice` is
# defined here and again below (simulating a second file). BEAM can only
# keep one definition loaded at a time, so whichever is compiled last wins,
# making every function from the losing module permanently unavailable.

defmodule Billing.Invoice do
  @moduledoc """
  Handles the creation and lifecycle of customer invoices.
  Defined in `lib/billing/invoice.ex`.
  """

  alias Billing.LineItem
  alias Billing.TaxPolicy

  @default_currency "USD"
  @due_days 30

  @type t :: %__MODULE__{
    id: String.t(),
    customer_id: String.t(),
    line_items: [LineItem.t()],
    currency: String.t(),
    issued_at: DateTime.t() | nil,
    due_at: DateTime.t() | nil,
    status: :draft | :issued | :paid | :void
  }

  defstruct [
    :id,
    :customer_id,
    line_items: [],
    currency: @default_currency,
    issued_at: nil,
    due_at: nil,
    status: :draft
  ]

  @doc "Build a new draft invoice for a customer."
  @spec build(String.t(), [LineItem.t()]) :: t()
  def build(customer_id, line_items) do
    %__MODULE__{
      id: generate_id(),
      customer_id: customer_id,
      line_items: line_items,
      status: :draft
    }
  end

  @doc "Compute the raw subtotal before tax or discounts."
  @spec subtotal(t()) :: Decimal.t()
  def subtotal(%__MODULE__{line_items: items}) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, LineItem.amount(item))
    end)
  end

  @doc "Compute the invoice total including applicable taxes."
  @spec total(t()) :: Decimal.t()
  def total(%__MODULE__{} = invoice) do
    sub = subtotal(invoice)
    tax = TaxPolicy.calculate(sub, invoice.customer_id)
    Decimal.add(sub, tax)
  end

  @doc "Apply a percentage discount to all line items."
  @spec apply_discount(t(), float()) :: t()
  def apply_discount(%__MODULE__{line_items: items} = invoice, pct)
      when pct >= 0.0 and pct <= 1.0 do
    discounted = Enum.map(items, &LineItem.apply_discount(&1, pct))
    %{invoice | line_items: discounted}
  end

  @doc "Transition the invoice from :draft to :issued, stamping timestamps."
  @spec finalize(t()) :: {:ok, t()} | {:error, String.t()}
  def finalize(%__MODULE__{status: :draft} = invoice) do
    now = DateTime.utc_now()
    due = DateTime.add(now, @due_days * 86_400, :second)
    {:ok, %{invoice | status: :issued, issued_at: now, due_at: due}}
  end

  def finalize(%__MODULE__{status: status}) do
    {:error, "Cannot finalize invoice in status: #{status}"}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END

# ── file: lib/billing/invoice/v2.ex  (developer intended a new namespace but
#    forgot to change the module name, so it collides with the one above) ──────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Billing.Invoice` block redefines the same
# module. At compile/load time BEAM emits a warning and discards the first
# definition, making `build/2`, `subtotal/1`, `total/1`, `apply_discount/2`,
# and `finalize/1` from the first block unreachable.

defmodule Billing.Invoice do
  @moduledoc """
  Revised invoice logic with support for multi-currency conversion.
  Intended to live in `lib/billing/invoice/v2.ex` but was accidentally
  given the same module name as the original implementation.
  """

  alias Billing.CurrencyConverter

  @supported_currencies ~w(USD EUR GBP JPY CAD)

  @doc "Convert an existing invoice total to a target currency."
  @spec convert_currency(map(), String.t()) ::
          {:ok, Decimal.t()} | {:error, String.t()}
  def convert_currency(%{currency: src} = invoice, target)
      when target in @supported_currencies do
    raw_total =
      Enum.reduce(invoice.line_items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Map.get(item, :amount, Decimal.new(0)))
      end)

    case CurrencyConverter.convert(raw_total, src, target) do
      {:ok, converted} -> {:ok, converted}
      {:error, reason} -> {:error, "Conversion failed: #{reason}"}
    end
  end

  def convert_currency(_invoice, target) do
    {:error, "Unsupported target currency: #{target}"}
  end

  @doc "Serialize invoice data for transmission to a payment gateway."
  @spec to_gateway_payload(map()) :: map()
  def to_gateway_payload(invoice) do
    %{
      reference: invoice.id,
      payer: invoice.customer_id,
      amount_cents: invoice |> Map.get(:line_items, []) |> sum_cents(),
      currency: invoice.currency,
      description: "Invoice #{invoice.id}"
    }
  end

  defp sum_cents(items) do
    items
    |> Enum.map(&(Map.get(&1, :unit_price, 0) * Map.get(&1, :quantity, 1)))
    |> Enum.sum()
    |> round()
  end
end

# VALIDATION: SMELL END
```
