```elixir
defmodule Billing.Invoices do
  @moduledoc """
  Handles invoice creation, persistence, and delivery for the billing subsystem.
  """

  require Logger

  alias Billing.Repo
  alias Billing.Schemas.Invoice
  alias Billing.Schemas.InvoiceLineItem
  alias Billing.Mailer
  alias Billing.PDFRenderer

  @default_currency "USD"
  @max_discount 100

  def create_invoice(
        customer_name,
        customer_email,
        customer_tax_id,
        due_days,
        currency,
        line_items,
        discount_percent,
        notes,
        send_email
      ) do
    with :ok <- validate_customer_fields(customer_name, customer_email, customer_tax_id),
         :ok <- validate_line_items(line_items),
         :ok <- validate_discount(discount_percent) do
      subtotal = compute_subtotal(line_items)
      discount_amount = subtotal * (discount_percent / 100)
      total = subtotal - discount_amount

      due_date =
        Date.utc_today()
        |> Date.add(due_days)
        |> Date.to_iso8601()

      invoice_attrs = %{
        customer_name: customer_name,
        customer_email: customer_email,
        customer_tax_id: customer_tax_id,
        currency: currency || @default_currency,
        subtotal: subtotal,
        discount_percent: discount_percent,
        discount_amount: discount_amount,
        total: total,
        due_date: due_date,
        notes: notes,
        status: :draft,
        inserted_at: DateTime.utc_now()
      }

      case Repo.insert(Invoice.changeset(%Invoice{}, invoice_attrs)) do
        {:ok, invoice} ->
          persisted_items = persist_line_items(invoice.id, line_items)
          Logger.info("Invoice #{invoice.id} created for #{customer_email}")

          if send_email do
            pdf = PDFRenderer.render(invoice, persisted_items)
            Mailer.send_invoice(customer_email, customer_name, invoice, pdf)
          end

          {:ok, invoice}

        {:error, changeset} ->
          Logger.error("Failed to create invoice: #{inspect(changeset.errors)}")
          {:error, :creation_failed}
      end
    end
  end

  defp validate_customer_fields(name, email, tax_id) do
    cond do
      is_nil(name) or String.trim(name) == "" ->
        {:error, :missing_customer_name}

      not String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) ->
        {:error, :invalid_customer_email}

      not is_nil(tax_id) and String.length(tax_id) < 4 ->
        {:error, :invalid_tax_id}

      true ->
        :ok
    end
  end

  defp validate_line_items([]), do: {:error, :no_line_items}

  defp validate_line_items(items) when is_list(items) do
    invalid =
      Enum.any?(items, fn item ->
        is_nil(item[:description]) or is_nil(item[:quantity]) or is_nil(item[:unit_price])
      end)

    if invalid, do: {:error, :invalid_line_item}, else: :ok
  end

  defp validate_discount(pct) when pct >= 0 and pct <= @max_discount, do: :ok
  defp validate_discount(_), do: {:error, :invalid_discount}

  defp compute_subtotal(items) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      line_total = Decimal.mult(item[:quantity], item[:unit_price])
      Decimal.add(acc, line_total)
    end)
  end

  defp persist_line_items(invoice_id, items) do
    Enum.map(items, fn item ->
      attrs = %{
        invoice_id: invoice_id,
        description: item[:description],
        quantity: item[:quantity],
        unit_price: item[:unit_price],
        total: Decimal.mult(item[:quantity], item[:unit_price])
      }

      {:ok, persisted} = Repo.insert(InvoiceLineItem.changeset(%InvoiceLineItem{}, attrs))
      persisted
    end)
  end
end
```
