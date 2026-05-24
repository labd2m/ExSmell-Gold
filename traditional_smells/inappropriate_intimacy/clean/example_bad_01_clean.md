```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Generates and manages customer invoices derived from confirmed orders.
  Handles the full invoice lifecycle: draft → finalized → void.
  """

  alias Billing.{Invoice, LineItem, Repo}
  alias Customers.Customer
  alias Tax.TaxConfig

  require Logger

  @invoice_number_prefix "INV"
  @default_payment_terms_days 30
  @max_line_items 500

  @spec generate(map(), String.t()) :: {:ok, Invoice.t()} | {:error, atom()}
  def generate(order, customer_id) do
    with {:ok, customer} <- Customer.fetch(customer_id),
         :ok <- validate_order(order) do

      account    = Customer.fetch_billing_account(customer)
      tax_config = TaxConfig.rates_for_region(account.region_code)

      subtotal          = compute_subtotal(order.line_items)
      vat_amount        = Decimal.mult(subtotal, tax_config.vat_rate)
      service_tax_amount = Decimal.mult(subtotal, tax_config.service_rate)
      total             = Decimal.add(subtotal, Decimal.add(vat_amount, service_tax_amount))
      terms_days        = account.payment_terms || @default_payment_terms_days

      invoice = %Invoice{
        number:            build_invoice_number(),
        customer_id:       customer_id,
        order_id:          order.id,
        billing_address:   account.billing_address,
        currency:          account.preferred_currency,
        payment_terms_days: terms_days,
        line_items:        Enum.map(order.line_items, &build_line_item/1),
        subtotal:          subtotal,
        vat:               vat_amount,
        service_tax:       service_tax_amount,
        total:             total,
        issued_at:         DateTime.utc_now(),
        due_at:            compute_due_date(terms_days),
        status:            :draft
      }

      case Repo.insert(invoice) do
        {:ok, saved}       -> {:ok, saved}
        {:error, changeset} -> {:error, {:persistence_failed, changeset}}
      end
    end
  end

  @spec finalize(String.t()) :: {:ok, Invoice.t()} | {:error, atom()}
  def finalize(invoice_id) do
    with {:ok, invoice} <- fetch_by_id(invoice_id),
         :ok <- ensure_status(invoice, :draft) do
      invoice
      |> Invoice.changeset(%{status: :finalized, finalized_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  @spec void(String.t(), String.t()) :: {:ok, Invoice.t()} | {:error, atom()}
  def void(invoice_id, reason) when is_binary(reason) and byte_size(reason) > 0 do
    with {:ok, invoice} <- fetch_by_id(invoice_id),
         :ok <- ensure_not_paid(invoice) do
      attrs = %{status: :void, void_reason: reason, voided_at: DateTime.utc_now()}

      case invoice |> Invoice.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          Logger.info("Invoice #{invoice_id} voided. Reason: #{reason}")
          {:ok, updated}

        {:error, changeset} ->
          {:error, {:persistence_failed, changeset}}
      end
    end
  end


  defp validate_order(%{line_items: items}) when length(items) > @max_line_items,
    do: {:error, :too_many_line_items}

  defp validate_order(%{line_items: []}), do: {:error, :empty_order}
  defp validate_order(_order), do: :ok

  defp compute_subtotal(line_items) do
    Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, Decimal.mult(item.unit_price, Decimal.new(item.quantity)))
    end)
  end

  defp build_line_item(item) do
    %LineItem{
      product_id:  item.product_id,
      description: item.description,
      quantity:    item.quantity,
      unit_price:  item.unit_price,
      line_total:  Decimal.mult(item.unit_price, Decimal.new(item.quantity))
    }
  end

  defp build_invoice_number do
    suffix    = :crypto.strong_rand_bytes(6) |> Base.encode16()
    date_part = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")
    "#{@invoice_number_prefix}-#{date_part}-#{suffix}"
  end

  defp compute_due_date(terms_days) do
    Date.utc_today()
    |> Date.add(terms_days)
    |> DateTime.new!(~T[23:59:59], "Etc/UTC")
  end

  defp fetch_by_id(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil     -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp ensure_status(%{status: s}, expected) when s == expected, do: :ok
  defp ensure_status(_, _), do: {:error, :invalid_status_transition}

  defp ensure_not_paid(%{status: :paid}), do: {:error, :invoice_already_paid}
  defp ensure_not_paid(_), do: :ok
end
```
