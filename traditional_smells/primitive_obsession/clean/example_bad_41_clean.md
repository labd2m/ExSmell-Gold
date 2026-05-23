```elixir
defmodule Billing.InvoiceService do
  @moduledoc """
  Handles invoice creation, discount application, and tax calculation
  for enterprise billing workflows.
  """

  require Logger

  @supported_currencies ["USD", "EUR", "GBP", "BRL", "JPY"]
  @max_discount_percent 0.40

  @spec create_invoice(String.t(), float(), String.t(), list(map())) ::
          {:ok, map()} | {:error, String.t()}
  def create_invoice(customer_id, base_amount, currency, line_items)
      when is_binary(customer_id) and is_float(base_amount) and is_binary(currency) do
    with :ok <- validate_currency(currency),
         :ok <- validate_amount(base_amount),
         :ok <- validate_line_items(line_items) do
      subtotal =
        Enum.reduce(line_items, base_amount, fn item, acc ->
          acc + item["unit_price"] * item["quantity"]
        end)

      invoice = %{
        id: generate_invoice_id(),
        customer_id: customer_id,
        subtotal: subtotal,
        currency: currency,
        line_items: line_items,
        status: "pending",
        issued_at: DateTime.utc_now()
      }

      Logger.info("Created invoice #{invoice.id} for customer #{customer_id}")
      {:ok, invoice}
    end
  end

  def create_invoice(_customer_id, _base_amount, _currency, _line_items) do
    {:error, "invalid_arguments"}
  end

  @spec apply_discount(map(), float(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def apply_discount(invoice, discount_value, discount_type)
      when is_float(discount_value) and is_binary(discount_type) do
    case discount_type do
      "percentage" ->
        if discount_value > @max_discount_percent do
          {:error, "discount_exceeds_maximum"}
        else
          discounted = invoice.subtotal * (1.0 - discount_value)
          {:ok, Map.put(invoice, :subtotal, discounted)}
        end

      "fixed" ->
        if discount_value > invoice.subtotal do
          {:error, "discount_exceeds_subtotal"}
        else
          discounted = invoice.subtotal - discount_value
          {:ok, Map.put(invoice, :subtotal, discounted)}
        end

      _ ->
        {:error, "unknown_discount_type"}
    end
  end

  @spec calculate_tax(map(), float()) :: {:ok, map()} | {:error, String.t()}
  def calculate_tax(invoice, tax_rate) when is_float(tax_rate) do
    if tax_rate < 0.0 or tax_rate > 1.0 do
      {:error, "invalid_tax_rate"}
    else
      tax_amount = invoice.subtotal * tax_rate
      total = invoice.subtotal + tax_amount

      updated =
        invoice
        |> Map.put(:tax_rate, tax_rate)
        |> Map.put(:tax_amount, tax_amount)
        |> Map.put(:total, total)

      {:ok, updated}
    end
  end

  @spec format_invoice_summary(map()) :: String.t()
  def format_invoice_summary(%{
        id: id,
        customer_id: customer_id,
        subtotal: subtotal,
        currency: currency,
        total: total,
        tax_amount: tax_amount
      }) do
    """
    Invoice ID  : #{id}
    Customer    : #{customer_id}
    Currency    : #{currency}
    Subtotal    : #{format_amount(subtotal, currency)}
    Tax         : #{format_amount(tax_amount, currency)}
    Total Due   : #{format_amount(total, currency)}
    """
  end

  def format_invoice_summary(_), do: "Incomplete invoice data"

  defp format_amount(amount, "JPY"), do: "¥#{round(amount)}"
  defp format_amount(amount, "EUR"), do: "€#{:erlang.float_to_binary(amount, decimals: 2)}"
  defp format_amount(amount, "GBP"), do: "£#{:erlang.float_to_binary(amount, decimals: 2)}"
  defp format_amount(amount, "BRL"), do: "R$#{:erlang.float_to_binary(amount, decimals: 2)}"
  defp format_amount(amount, _), do: "$#{:erlang.float_to_binary(amount, decimals: 2)}"

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(_), do: {:error, "unsupported_currency"}

  defp validate_amount(amount) when amount > 0.0, do: :ok
  defp validate_amount(_), do: {:error, "amount_must_be_positive"}

  defp validate_line_items([_ | _]), do: :ok
  defp validate_line_items(_), do: {:error, "line_items_cannot_be_empty"}

  defp generate_invoice_id do
    "INV-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end
```
