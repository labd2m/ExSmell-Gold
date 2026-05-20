# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `apply_discount/1` function, lines with multi-clause heads
- **Affected function(s):** `apply_discount/1`
- **Short explanation:** The function extracts multiple fields from `%Invoice{}` in each clause head — `total`, `customer_tier`, `due_date`, `invoice_id`, and `line_items`. Only `total` and `customer_tier` are needed for the guard/pattern match, while `due_date`, `invoice_id`, and `line_items` are only used inside the function body. This mixing makes it hard to quickly understand which extractions drive clause selection and which are just convenience bindings.

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

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because all five fields (total, customer_tier,
  # due_date, invoice_id, line_items) are extracted in every clause head, but
  # only `total` and `customer_tier` are relevant to guard/pattern matching.
  # `due_date`, `invoice_id`, and `line_items` are body-only bindings that
  # inflate the clause signature and obscure which extractions matter for dispatch.

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

  # VALIDATION: SMELL END

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
