```elixir
defmodule InvoiceLineItemProcessor do
  @moduledoc """
  Processes individual line items on invoices, applying tax rules,
  mapping to general ledger accounts, and formatting display strings
  for the billing subsystem.
  """

  require Logger

  @item_types [:subscription, :usage, :one_time, :credit]

  def valid_item_types, do: @item_types







  @doc """
  Returns the applicable tax rate (as a float between 0.0 and 1.0) for the
  given line item type.
  """
  def tax_rate(%{item_type: item_type}) do
    case item_type do
      :subscription -> 0.0
      :usage -> 0.12
      :one_time -> 0.12
      :credit -> 0.0
      _ -> 0.0
    end
  end

  @doc """
  Returns the general ledger account code to which this line item type
  should be posted.
  """
  def gl_account_code(%{item_type: item_type}) do
    case item_type do
      :subscription -> "4000-SAAS"
      :usage -> "4100-USAGE"
      :one_time -> "4200-SERVICES"
      :credit -> "2100-DEFERRED"
      _ -> "4999-MISC"
    end
  end

  @doc """
  Returns a short prefix string used when auto-generating line item descriptions
  in the invoice PDF.
  """
  def line_item_description_prefix(%{item_type: item_type}) do
    case item_type do
      :subscription -> "Subscription:"
      :usage -> "Usage charge:"
      :one_time -> "One-time service:"
      :credit -> "Credit applied:"
      _ -> "Charge:"
    end
  end



  @doc """
  Calculates the tax amount for a line item given its unit price and quantity.
  """
  def calculate_tax(%{unit_price: unit_price, quantity: quantity} = item) do
    rate = tax_rate(item)
    subtotal = unit_price * quantity
    Float.round(subtotal * rate, 2)
  end

  @doc """
  Builds the total for a line item including tax.
  """
  def line_item_total(%{unit_price: unit_price, quantity: quantity} = item) do
    subtotal = unit_price * quantity
    tax = calculate_tax(item)
    %{subtotal: subtotal, tax: tax, total: subtotal + tax}
  end

  @doc """
  Formats a line item into a display-ready map for invoice rendering.
  """
  def format_for_invoice(%{description: description} = item) do
    prefix = line_item_description_prefix(item)
    totals = line_item_total(item)

    %{
      gl_code: gl_account_code(item),
      display_description: "#{prefix} #{description}",
      subtotal: totals.subtotal,
      tax_rate: tax_rate(item),
      tax_amount: totals.tax,
      total: totals.total
    }
  end

  @doc """
  Validates that a line item has all required fields and a recognized item type.
  """
  def validate(%{item_type: item_type, unit_price: price, quantity: qty} = item)
      when item_type in @item_types and is_number(price) and is_integer(qty) and qty > 0 do
    {:ok, item}
  end

  def validate(%{item_type: type}) when type not in @item_types do
    {:error, {:unknown_item_type, type}}
  end

  def validate(_), do: {:error, :invalid_line_item}

  @doc """
  Processes a full list of line items for an invoice, returning formatted
  line items and aggregate totals.
  """
  def process_invoice_items(items) when is_list(items) do
    {valid, invalid} =
      Enum.reduce(items, {[], []}, fn item, {ok_acc, err_acc} ->
        case validate(item) do
          {:ok, v} -> {[v | ok_acc], err_acc}
          {:error, reason} -> {ok_acc, [{reason, item} | err_acc]}
        end
      end)

    if Enum.any?(invalid) do
      Logger.warning("#{length(invalid)} invalid line items were skipped during processing.")
    end

    formatted = Enum.map(valid, &format_for_invoice/1)

    invoice_total = Enum.reduce(formatted, 0.0, fn f, acc -> acc + f.total end)
    invoice_tax = Enum.reduce(formatted, 0.0, fn f, acc -> acc + f.tax_amount end)

    %{
      line_items: formatted,
      subtotal: invoice_total - invoice_tax,
      total_tax: Float.round(invoice_tax, 2),
      grand_total: Float.round(invoice_total, 2),
      skipped: length(invalid)
    }
  end
end
```
