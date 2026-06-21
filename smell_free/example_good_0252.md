# File: `example_good_252.md`

```elixir
defmodule Billing.InvoiceBuilder do
  @moduledoc """
  Pure functional builder for constructing invoice documents from a set
  of line items, tax rules, and discount schedules.

  An invoice is assembled incrementally using a pipeline of builder steps.
  The final `build/1` call validates the assembled state and produces a
  completed invoice struct. No I/O occurs; callers persist the result.
  """

  @enforce_keys [:customer_id, :currency]
  defstruct [
    :customer_id,
    :currency,
    :due_date,
    :reference,
    line_items: [],
    tax_rate_bps: 0,
    discount_cents: 0,
    notes: nil
  ]

  @type t :: %__MODULE__{}
  @type amount_cents :: non_neg_integer()

  @type line_item :: %{
          required(:description) => String.t(),
          required(:quantity) => pos_integer(),
          required(:unit_price_cents) => amount_cents()
        }

  @type built_invoice :: %{
          customer_id: String.t(),
          currency: String.t(),
          reference: String.t(),
          due_date: Date.t() | nil,
          line_items: [line_item()],
          subtotal_cents: amount_cents(),
          discount_cents: amount_cents(),
          taxable_cents: amount_cents(),
          tax_cents: amount_cents(),
          total_cents: amount_cents(),
          notes: String.t() | nil
        }

  @type build_result :: {:ok, built_invoice()} | {:error, [String.t()]}

  @doc """
  Creates a new invoice builder for `customer_id` denominated in `currency`.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(customer_id, currency) when is_binary(customer_id) and is_binary(currency) do
    %__MODULE__{customer_id: customer_id, currency: String.upcase(currency)}
  end

  @doc """
  Adds a line item to the invoice under construction.
  """
  @spec add_line(t(), String.t(), pos_integer(), amount_cents()) :: t()
  def add_line(%__MODULE__{} = builder, description, quantity, unit_price_cents)
      when is_binary(description) and is_integer(quantity) and quantity > 0 and
             is_integer(unit_price_cents) and unit_price_cents >= 0 do
    item = %{description: description, quantity: quantity, unit_price_cents: unit_price_cents}
    %{builder | line_items: builder.line_items ++ [item]}
  end

  @doc """
  Sets a tax rate expressed in basis points (1 bps = 0.01%).
  """
  @spec with_tax(t(), non_neg_integer()) :: t()
  def with_tax(%__MODULE__{} = builder, rate_bps)
      when is_integer(rate_bps) and rate_bps >= 0 do
    %{builder | tax_rate_bps: rate_bps}
  end

  @doc """
  Applies a fixed discount amount in cents.
  """
  @spec with_discount(t(), amount_cents()) :: t()
  def with_discount(%__MODULE__{} = builder, discount_cents)
      when is_integer(discount_cents) and discount_cents >= 0 do
    %{builder | discount_cents: discount_cents}
  end

  @doc """
  Sets a payment due date on the invoice.
  """
  @spec due_on(t(), Date.t()) :: t()
  def due_on(%__MODULE__{} = builder, %Date{} = due_date) do
    %{builder | due_date: due_date}
  end

  @doc """
  Attaches a human-readable reference identifier.
  """
  @spec with_reference(t(), String.t()) :: t()
  def with_reference(%__MODULE__{} = builder, reference) when is_binary(reference) do
    %{builder | reference: reference}
  end

  @doc """
  Adds optional notes to the invoice.
  """
  @spec with_notes(t(), String.t()) :: t()
  def with_notes(%__MODULE__{} = builder, notes) when is_binary(notes) do
    %{builder | notes: notes}
  end

  @doc """
  Validates the builder state and produces a completed invoice map.

  Returns `{:ok, invoice}` when all required fields are present and
  at least one line item exists, or `{:error, violations}`.
  """
  @spec build(t()) :: build_result()
  def build(%__MODULE__{} = builder) do
    violations = validate(builder)

    case violations do
      [] -> {:ok, compute_invoice(builder)}
      _ -> {:error, violations}
    end
  end

  defp validate(builder) do
    []
    |> check(builder.line_items == [], "at least one line item is required")
    |> check(is_nil(builder.reference), "a reference is required")
    |> check(
      builder.discount_cents > subtotal(builder.line_items),
      "discount cannot exceed the subtotal"
    )
  end

  defp check(violations, false, _message), do: violations
  defp check(violations, true, message), do: [message | violations]

  defp compute_invoice(builder) do
    subtotal = subtotal(builder.line_items)
    discount = min(builder.discount_cents, subtotal)
    taxable = subtotal - discount
    tax = round(taxable * builder.tax_rate_bps / 10_000)
    total = taxable + tax

    %{
      customer_id: builder.customer_id,
      currency: builder.currency,
      reference: builder.reference,
      due_date: builder.due_date,
      line_items: builder.line_items,
      subtotal_cents: subtotal,
      discount_cents: discount,
      taxable_cents: taxable,
      tax_cents: tax,
      total_cents: total,
      notes: builder.notes
    }
  end

  defp subtotal(line_items) do
    Enum.sum(Enum.map(line_items, fn item -> item.quantity * item.unit_price_cents end))
  end
end
```
