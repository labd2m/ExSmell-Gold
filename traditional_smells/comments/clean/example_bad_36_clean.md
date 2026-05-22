```elixir
defmodule BillingService do
  @moduledoc """
  Handles invoice generation and billing calculations for customer accounts.
  """

  alias BillingService.{Invoice, LineItem, TaxRule}

  @tax_rates %{
    standard: 0.20,
    reduced: 0.05,
    zero: 0.00
  }

  @doc """
  Applies an early-payment discount to an invoice if the due date is within
  the configured threshold.
  """
  def apply_early_payment_discount(%Invoice{} = invoice, discount_rate)
      when is_float(discount_rate) and discount_rate > 0.0 do
    discounted_total = invoice.subtotal * (1.0 - discount_rate)

    %Invoice{invoice | subtotal: discounted_total, discount_applied: discount_rate}
  end


  # Calculates the total amount for an invoice, including applicable taxes.
  # Accepts a list of line items and a tax category atom (:standard, :reduced, :zero).
  # Returns a map with keys :subtotal, :tax_amount, and :total.
  # Raises ArgumentError if an unknown tax category is provided.
  def calculate_invoice_total(line_items, tax_category)
      when is_list(line_items) and is_atom(tax_category) do
    rate = Map.fetch!(@tax_rates, tax_category)

    subtotal =
      line_items
      |> Enum.map(fn %LineItem{quantity: qty, unit_price: price} -> qty * price end)
      |> Enum.sum()

    tax_amount = Float.round(subtotal * rate, 2)
    total = Float.round(subtotal + tax_amount, 2)

    %{subtotal: subtotal, tax_amount: tax_amount, total: total}
  end


  @doc """
  Formats a monetary value as a string with the given currency symbol.
  """
  def format_amount(amount, currency \\ "USD") when is_float(amount) do
    formatted = :erlang.float_to_binary(amount, decimals: 2)
    "#{currency} #{formatted}"
  end

  @doc """
  Generates a unique invoice reference code using the account ID and current timestamp.
  """
  def generate_invoice_ref(account_id) when is_binary(account_id) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "INV-#{account_id}-#{timestamp}"
  end

  @doc """
  Validates that all required fields are present and non-nil on an invoice struct.
  """
  def validate_invoice(%Invoice{} = invoice) do
    required_fields = [:customer_id, :line_items, :due_date, :currency]

    missing =
      Enum.filter(required_fields, fn field ->
        Map.get(invoice, field) |> is_nil()
      end)

    case missing do
      [] -> {:ok, invoice}
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  @doc """
  Applies a list of `TaxRule` overrides to a set of line items, returning
  an updated list with adjusted unit prices.
  """
  def apply_tax_rules(line_items, tax_rules) when is_list(line_items) and is_list(tax_rules) do
    Enum.map(line_items, fn item ->
      applicable_rule =
        Enum.find(tax_rules, fn %TaxRule{product_code: code} ->
          code == item.product_code
        end)

      case applicable_rule do
        nil -> item
        %TaxRule{override_rate: rate} -> %LineItem{item | unit_price: item.unit_price * (1 + rate)}
      end
    end)
  end
end
```
