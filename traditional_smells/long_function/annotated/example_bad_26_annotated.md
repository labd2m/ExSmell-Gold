# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `InvoiceProcessor.process/2`
- **Affected function(s):** `process/2`
- **Short explanation:** The `process/2` function handles validation, discount calculation, tax application, line-item totalling, audit logging, and notification dispatch all in one monolithic body. Each of those concerns could and should be extracted into its own focused helper function.

---

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Processes incoming invoices for enterprise customers,
  applying discounts, taxes, and persisting audit records.
  """

  require Logger

  alias Billing.{Invoice, LineItem, AuditLog, Mailer}

  @tax_rate 0.15
  @premium_threshold 10_000.00
  @early_payment_discount 0.05
  @volume_discount_threshold 20

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `process/2` accumulates validation,
  # discount logic, tax computation, subtotal/total calculation, audit
  # persistence, and e-mail notification into a single function body that
  # exceeds 80 lines and groups many unrelated responsibilities together.
  def process(%Invoice{} = invoice, opts \\ []) do
    notify_on_complete = Keyword.get(opts, :notify, true)
    audit_user         = Keyword.get(opts, :audit_user, "system")

    # ── Step 1: basic validation ──────────────────────────────────────────
    cond do
      is_nil(invoice.customer_id) ->
        {:error, :missing_customer_id}

      invoice.line_items == [] ->
        {:error, :empty_line_items}

      is_nil(invoice.due_date) ->
        {:error, :missing_due_date}

      true ->
        # ── Step 2: validate individual line items ────────────────────────
        invalid_items =
          Enum.filter(invoice.line_items, fn item ->
            is_nil(item.sku) or item.quantity <= 0 or item.unit_price < 0
          end)

        if invalid_items != [] do
          {:error, {:invalid_line_items, Enum.map(invalid_items, & &1.sku)}}
        else
          # ── Step 3: compute subtotals per line ───────────────────────────
          costed_items =
            Enum.map(invoice.line_items, fn item ->
              subtotal = Float.round(item.quantity * item.unit_price, 2)
              Map.put(item, :subtotal, subtotal)
            end)

          gross_total = Enum.reduce(costed_items, 0.0, &(&1.subtotal + &2))

          # ── Step 4: apply volume discount ────────────────────────────────
          total_units = Enum.sum(Enum.map(invoice.line_items, & &1.quantity))

          gross_after_volume =
            if total_units >= @volume_discount_threshold do
              rate = if total_units >= 50, do: 0.08, else: 0.04
              Float.round(gross_total * (1 - rate), 2)
            else
              gross_total
            end

          # ── Step 5: apply early-payment discount ─────────────────────────
          days_until_due =
            Date.diff(invoice.due_date, Date.utc_today())

          gross_after_early =
            if days_until_due >= 10 do
              Float.round(gross_after_volume * (1 - @early_payment_discount), 2)
            else
              gross_after_volume
            end

          # ── Step 6: apply premium-customer discount ───────────────────────
          gross_after_premium =
            if gross_after_early >= @premium_threshold do
              Float.round(gross_after_early * 0.97, 2)
            else
              gross_after_early
            end

          # ── Step 7: calculate tax ─────────────────────────────────────────
          tax_amount  = Float.round(gross_after_premium * @tax_rate, 2)
          final_total = Float.round(gross_after_premium + tax_amount, 2)

          # ── Step 8: build the processed invoice struct ────────────────────
          processed =
            %{invoice |
              line_items:  costed_items,
              subtotal:    gross_total,
              discount:    Float.round(gross_total - gross_after_premium, 2),
              tax:         tax_amount,
              total:       final_total,
              status:      :processed,
              processed_at: DateTime.utc_now()
            }

          # ── Step 9: persist audit log ─────────────────────────────────────
          audit_entry = %AuditLog{
            entity:     "invoice",
            entity_id:  invoice.id,
            action:     "processed",
            actor:      audit_user,
            metadata:   %{total: final_total, items: length(costed_items)},
            inserted_at: DateTime.utc_now()
          }

          case AuditLog.insert(audit_entry) do
            {:error, reason} ->
              Logger.warning("Audit log failed for invoice #{invoice.id}: #{inspect(reason)}")

            _ ->
              :ok
          end

          # ── Step 10: optionally notify the customer ───────────────────────
          if notify_on_complete do
            email_body =
              """
              Dear #{invoice.customer_name},

              Your invoice ##{invoice.id} has been processed.
              Total due: $#{final_total}
              Due date:  #{invoice.due_date}

              Thank you for your business.
              """

            case Mailer.send_email(invoice.customer_email, "Invoice Processed", email_body) do
              {:ok, _}         -> Logger.info("Notification sent for invoice #{invoice.id}")
              {:error, reason} -> Logger.error("Failed to notify customer: #{inspect(reason)}")
            end
          end

          {:ok, processed}
        end
    end
  end
  # VALIDATION: SMELL END

  defp format_currency(amount), do: "$#{:erlang.float_to_binary(amount, decimals: 2)}"
end
```
