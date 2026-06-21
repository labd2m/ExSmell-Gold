## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `format_line_item/1` — the `to_string(description)` call
- **Affected function(s):** `Billing.InvoiceBuilder.format_line_item/1`
- **Short explanation:** `to_string/1` dispatches through the `String.Chars` protocol. No guard or pattern match restricts `description` to types that implement it. Passing a `Map`, `Tuple`, or arbitrary struct without a `String.Chars` implementation raises `Protocol.UndefinedError` at runtime.

```elixir
defmodule Billing.InvoiceBuilder do
  @moduledoc """
  Assembles invoice documents from validated billing data.
  Consumed by the billing pipeline to produce printable and exportable invoices.
  """

  alias Billing.{LineItem, TaxPolicy, Customer}

  @default_currency "USD"
  @line_item_max_chars 120

  def build_invoice(customer_id, line_items, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)
    due_date = Keyword.get(opts, :due_date, default_due_date())
    notes = Keyword.get(opts, :notes, "")

    with {:ok, customer} <- Customer.fetch(customer_id),
         {:ok, validated_items} <- validate_line_items(line_items),
         {:ok, tax_policy} <- TaxPolicy.for_region(customer.region) do
      subtotal = compute_subtotal(validated_items)
      tax = TaxPolicy.apply(tax_policy, subtotal)
      total = Decimal.add(subtotal, tax)

      invoice = %{
        invoice_number: generate_invoice_number(),
        customer: customer,
        currency: currency,
        line_items: Enum.map(validated_items, &format_line_item/1),
        subtotal: subtotal,
        tax: tax,
        total: total,
        due_date: due_date,
        notes: notes,
        issued_at: DateTime.utc_now()
      }

      {:ok, invoice}
    end
  end

  def validate_line_items([]), do: {:error, :empty_line_items}

  def validate_line_items(items) do
    result =
      Enum.reduce_while(items, [], fn item, acc ->
        case LineItem.validate(item) do
          {:ok, valid_item} -> {:cont, [valid_item | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _} = err -> err
      reversed -> {:ok, Enum.reverse(reversed)}
    end
  end

  def compute_subtotal(items) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
    end)
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because `to_string(description)` implicitly uses the
  # VALIDATION: `String.Chars` protocol. The function has no guard clause or pattern match
  # VALIDATION: that restricts `description` to types implementing this protocol (e.g.,
  # VALIDATION: binary or atom). If a caller provides a Map, Tuple, PID, or a struct
  # VALIDATION: without `String.Chars`, a `Protocol.UndefinedError` is raised at runtime.
  def format_line_item(%LineItem{description: description, unit_price: price, quantity: qty}) do
    formatted_description =
      description
      |> to_string()
      |> String.trim()
      |> String.slice(0, @line_item_max_chars)

    %{
      description: formatted_description,
      unit_price: Decimal.to_string(price),
      quantity: qty,
      line_total: Decimal.to_string(Decimal.mult(price, qty))
    }
  end
  # VALIDATION: SMELL END

  def format_currency_amount(amount, currency \\ @default_currency) do
    "#{currency} #{Decimal.to_string(amount)}"
  end

  def generate_invoice_number do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "INV-#{timestamp}-#{random}"
  end

  def export_to_map(%{} = invoice) do
    %{
      invoice_number: invoice.invoice_number,
      customer_name: invoice.customer.name,
      customer_email: invoice.customer.email,
      currency: invoice.currency,
      line_items: invoice.line_items,
      subtotal: Decimal.to_string(invoice.subtotal),
      tax: Decimal.to_string(invoice.tax),
      total: Decimal.to_string(invoice.total),
      due_date: Date.to_iso8601(invoice.due_date),
      issued_at: DateTime.to_iso8601(invoice.issued_at)
    }
  end

  defp default_due_date, do: Date.utc_today() |> Date.add(30)
end
```
