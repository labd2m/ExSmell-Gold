# Annotated Example – Code Smell

| Field              | Value                                                                 |
|--------------------|-----------------------------------------------------------------------|
| **Smell name**     | Long Function                                                         |
| **Location**       | `Billing.InvoiceProcessor.process_invoice/2`                          |
| **Affected fn(s)** | `process_invoice/2`                                                   |
| **Explanation**    | `process_invoice/2` accumulates responsibilities across many unrelated stages — validating the customer, computing line-item totals, applying discount rules, building the invoice struct, persisting it, and dispatching a notification — all in a single function body. Each stage is a distinct concern that should be extracted into its own focused helper. The function exceeds 80 lines and requires inline section comments to remain navigable, which is a direct symptom of poor cohesion. |

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles the full lifecycle of invoice generation for subscription customers.
  """

  require Logger

  alias Billing.{Customer, Invoice, InvoiceItem, Repo, Mailer}
  alias Billing.Discounts

  @tax_rate 0.12
  @late_fee_threshold_days 30
  @max_credit_carry 500_00

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `process_invoice/2` is a monolithic function
  # that handles customer validation, line-item computation, discount resolution,
  # tax/fee calculation, struct assembly, persistence, and email dispatch — all
  # inlined without delegation to focused helpers.  The function is well over
  # 80 lines long and groups many distinct responsibilities into one body.
  def process_invoice(customer_id, billing_period) do
    # --- 1. Load and validate customer ---
    customer = Repo.get!(Customer, customer_id)

    unless customer.active do
      Logger.warn("Attempted to invoice inactive customer #{customer_id}")
      {:error, :customer_inactive}
    end

    unless customer.payment_method != nil do
      Logger.warn("Customer #{customer_id} has no payment method on file")
      {:error, :no_payment_method}
    end

    # --- 2. Collect billable line items for the period ---
    raw_items =
      Repo.all(
        from i in InvoiceItem,
          where:
            i.customer_id == ^customer_id and
              i.billed == false and
              i.period == ^billing_period,
          order_by: [asc: i.inserted_at]
      )

    if Enum.empty?(raw_items) do
      Logger.info("No billable items for customer #{customer_id} in #{billing_period}")
      {:ok, :nothing_to_bill}
    end

    # --- 3. Compute subtotals per item ---
    enriched_items =
      Enum.map(raw_items, fn item ->
        unit_price =
          if item.override_price do
            item.override_price
          else
            item.product.base_price
          end

        quantity = max(item.quantity, 1)
        subtotal = unit_price * quantity

        Map.merge(item, %{unit_price: unit_price, subtotal: subtotal})
      end)

    subtotal_amount = Enum.reduce(enriched_items, 0, fn i, acc -> acc + i.subtotal end)

    # --- 4. Resolve applicable discounts ---
    applicable_discounts = Discounts.for_customer(customer, billing_period)

    discount_amount =
      Enum.reduce(applicable_discounts, 0, fn discount, acc ->
        cond do
          discount.type == :percentage ->
            acc + round(subtotal_amount * discount.value / 100)

          discount.type == :fixed ->
            acc + discount.value

          true ->
            acc
        end
      end)

    discounted_subtotal = max(subtotal_amount - discount_amount, 0)

    # --- 5. Apply credit balance ---
    credit_to_apply = min(customer.credit_balance, min(discounted_subtotal, @max_credit_carry))
    post_credit_amount = discounted_subtotal - credit_to_apply

    # --- 6. Calculate tax and late fees ---
    tax_amount = round(post_credit_amount * @tax_rate)

    days_since_last_payment =
      Date.diff(Date.utc_today(), customer.last_payment_date || Date.utc_today())

    late_fee =
      if days_since_last_payment > @late_fee_threshold_days do
        round(post_credit_amount * 0.015)
      else
        0
      end

    total_due = post_credit_amount + tax_amount + late_fee

    # --- 7. Build invoice struct and persist ---
    invoice_attrs = %{
      customer_id: customer.id,
      billing_period: billing_period,
      line_items: enriched_items,
      subtotal: subtotal_amount,
      discount_amount: discount_amount,
      credit_applied: credit_to_apply,
      tax_amount: tax_amount,
      late_fee: late_fee,
      total_due: total_due,
      status: :pending,
      issued_at: DateTime.utc_now(),
      due_date: Date.add(Date.utc_today(), 30)
    }

    {:ok, invoice} =
      %Invoice{}
      |> Invoice.changeset(invoice_attrs)
      |> Repo.insert()

    Repo.update!(Customer.changeset(customer, %{credit_balance: customer.credit_balance - credit_to_apply}))

    Enum.each(raw_items, fn item ->
      Repo.update!(InvoiceItem.changeset(item, %{billed: true, invoice_id: invoice.id}))
    end)

    # --- 8. Send invoice email ---
    email_result =
      Mailer.send_invoice_email(customer.email, %{
        customer_name: "#{customer.first_name} #{customer.last_name}",
        invoice_number: invoice.id,
        billing_period: billing_period,
        total_due: total_due,
        due_date: invoice.due_date
      })

    case email_result do
      {:ok, _} ->
        Logger.info("Invoice #{invoice.id} emailed to #{customer.email}")

      {:error, reason} ->
        Logger.error("Failed to send invoice #{invoice.id} email: #{inspect(reason)}")
    end

    {:ok, invoice}
  end
  # VALIDATION: SMELL END

  defp format_period(period), do: Calendar.strftime(period, "%B %Y")
end
```
