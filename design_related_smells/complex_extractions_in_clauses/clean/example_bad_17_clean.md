```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice processing, discount application, and finalization
  for the billing pipeline.
  """

  alias Billing.{Invoice, LineItem, AuditLog}

  @premium_discount 0.20
  @standard_discount 0.10
  @basic_discount 0.05


  def apply_discount(%Invoice{
        total: total,
        customer_tier: customer_tier,
        due_date: due_date,
        invoice_id: invoice_id,
        line_items: line_items
      })
      when customer_tier == :premium and total > 1_000 do
    discounted = Float.round(total * (1 - @premium_discount), 2)

    audit_entry = AuditLog.build(invoice_id, :discount_applied, %{
      tier: customer_tier,
      original: total,
      discounted: discounted
    })

    AuditLog.persist(audit_entry)

    enriched_items = Enum.map(line_items, &LineItem.mark_discounted(&1, @premium_discount))

    %Invoice{
      invoice_id: invoice_id,
      total: discounted,
      due_date: due_date,
      customer_tier: customer_tier,
      line_items: enriched_items,
      discount_applied: @premium_discount
    }
  end

  def apply_discount(%Invoice{
        total: total,
        customer_tier: customer_tier,
        due_date: due_date,
        invoice_id: invoice_id,
        line_items: line_items
      })
      when customer_tier == :standard and total > 500 do
    discounted = Float.round(total * (1 - @standard_discount), 2)

    audit_entry = AuditLog.build(invoice_id, :discount_applied, %{
      tier: customer_tier,
      original: total,
      discounted: discounted
    })

    AuditLog.persist(audit_entry)

    enriched_items = Enum.map(line_items, &LineItem.mark_discounted(&1, @standard_discount))

    %Invoice{
      invoice_id: invoice_id,
      total: discounted,
      due_date: due_date,
      customer_tier: customer_tier,
      line_items: enriched_items,
      discount_applied: @standard_discount
    }
  end

  def apply_discount(%Invoice{
        total: total,
        customer_tier: customer_tier,
        due_date: due_date,
        invoice_id: invoice_id,
        line_items: line_items
      })
      when customer_tier == :basic do
    discounted = Float.round(total * (1 - @basic_discount), 2)

    audit_entry = AuditLog.build(invoice_id, :discount_applied, %{
      tier: customer_tier,
      original: total,
      discounted: discounted
    })

    AuditLog.persist(audit_entry)

    enriched_items = Enum.map(line_items, &LineItem.mark_discounted(&1, @basic_discount))

    %Invoice{
      invoice_id: invoice_id,
      total: discounted,
      due_date: due_date,
      customer_tier: customer_tier,
      line_items: enriched_items,
      discount_applied: @basic_discount
    }
  end

  def apply_discount(%Invoice{
        total: total,
        customer_tier: customer_tier,
        due_date: due_date,
        invoice_id: invoice_id,
        line_items: line_items
      }) do
    _ = {due_date, invoice_id, line_items, customer_tier}
    {:no_discount, total}
  end


  def finalize(%Invoice{} = invoice) do
    invoice
    |> apply_discount()
    |> stamp_finalized_at()
  end

  defp stamp_finalized_at(%Invoice{} = invoice) do
    %Invoice{invoice | finalized_at: DateTime.utc_now()}
  end

  defp stamp_finalized_at({:no_discount, total}), do: {:ok, total}
end
```
