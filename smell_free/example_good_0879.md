```elixir
defmodule MyApp.Billing.InvoiceBuilder do
  @moduledoc """
  Assembles a complete `Invoice` value object from its constituent parts:
  a subscription record, usage line items, applicable tax rates, and any
  adjustments. The builder validates that the invoice balances before
  returning it; a negative total is rejected as invalid.

  The result is a pure data struct ready for persistence or PDF rendering
  without any side effects from the builder itself.
  """

  alias MyApp.Billing.{Invoice, InvoiceLine, TaxRate}

  @type builder_error ::
          {:error, :negative_total}
          | {:error, :no_line_items}
          | {:error, :missing_required_field, atom()}

  @type invoice_input :: %{
          required(:subscription_id) => String.t(),
          required(:customer_id) => String.t(),
          required(:billing_period_start) => Date.t(),
          required(:billing_period_end) => Date.t(),
          required(:lines) => [map()],
          optional(:tax_rates) => [TaxRate.t()],
          optional(:adjustments) => [map()],
          optional(:notes) => String.t()
        }

  @doc """
  Builds and validates an `Invoice` struct from `input`.
  Returns `{:ok, invoice}` or a structured error tuple.
  """
  @spec build(invoice_input()) :: {:ok, Invoice.t()} | builder_error()
  def build(input) when is_map(input) do
    with :ok <- validate_required_fields(input),
         :ok <- validate_lines(input.lines),
         {:ok, line_items} <- build_line_items(input.lines),
         {:ok, adjusted_lines} <- apply_adjustments(line_items, Map.get(input, :adjustments, [])),
         {:ok, tax_lines} <- compute_taxes(adjusted_lines, Map.get(input, :tax_rates, [])),
         subtotal <- sum_lines(adjusted_lines),
         total_tax <- sum_lines(tax_lines),
         total <- subtotal + total_tax,
         :ok <- validate_total(total) do
      invoice = %Invoice{
        number: nil,
        subscription_id: input.subscription_id,
        customer_id: input.customer_id,
        billing_period_start: input.billing_period_start,
        billing_period_end: input.billing_period_end,
        line_items: adjusted_lines,
        tax_lines: tax_lines,
        subtotal_cents: subtotal,
        tax_cents: total_tax,
        total_cents: total,
        notes: Map.get(input, :notes),
        status: :draft,
        issued_at: nil
      }

      {:ok, invoice}
    end
  end

  @spec validate_required_fields(invoice_input()) :: :ok | builder_error()
  defp validate_required_fields(input) do
    required = [:subscription_id, :customer_id, :billing_period_start, :billing_period_end, :lines]

    case Enum.find(required, fn f -> is_nil(Map.get(input, f)) end) do
      nil -> :ok
      field -> {:error, :missing_required_field, field}
    end
  end

  @spec validate_lines([map()]) :: :ok | {:error, :no_line_items}
  defp validate_lines([]), do: {:error, :no_line_items}
  defp validate_lines(_), do: :ok

  @spec build_line_items([map()]) :: {:ok, [InvoiceLine.t()]}
  defp build_line_items(lines) do
    items =
      Enum.map(lines, fn line ->
        %InvoiceLine{
          description: line.description,
          quantity: Map.get(line, :quantity, 1),
          unit_price_cents: line.unit_price_cents,
          total_cents: Map.get(line, :quantity, 1) * line.unit_price_cents,
          type: :charge
        }
      end)

    {:ok, items}
  end

  @spec apply_adjustments([InvoiceLine.t()], [map()]) :: {:ok, [InvoiceLine.t()]}
  defp apply_adjustments(lines, []), do: {:ok, lines}

  defp apply_adjustments(lines, adjustments) do
    adj_lines =
      Enum.map(adjustments, fn adj ->
        %InvoiceLine{
          description: adj.description,
          quantity: 1,
          unit_price_cents: adj.amount_cents,
          total_cents: adj.amount_cents,
          type: :adjustment
        }
      end)

    {:ok, lines ++ adj_lines}
  end

  @spec compute_taxes([InvoiceLine.t()], [TaxRate.t()]) :: {:ok, [InvoiceLine.t()]}
  defp compute_taxes(lines, []), do: {:ok, []}

  defp compute_taxes(lines, tax_rates) do
    subtotal = sum_lines(lines)

    tax_lines =
      Enum.map(tax_rates, fn rate ->
        tax_cents = round(subtotal * rate.rate_bps / 10_000)

        %InvoiceLine{
          description: "#{rate.label} (#{rate.rate_bps / 100}%)",
          quantity: 1,
          unit_price_cents: tax_cents,
          total_cents: tax_cents,
          type: :tax
        }
      end)

    {:ok, tax_lines}
  end

  @spec sum_lines([InvoiceLine.t()]) :: integer()
  defp sum_lines(lines), do: Enum.sum_by(lines, & &1.total_cents)

  @spec validate_total(integer()) :: :ok | {:error, :negative_total}
  defp validate_total(total) when total >= 0, do: :ok
  defp validate_total(_), do: {:error, :negative_total}
end
```
