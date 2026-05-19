# Annotated Example 01 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `BillingTracker`, `InvoiceProcessor`, `PaymentGateway`, and `BillingReporter` all interact directly with the Agent PID
- **Affected functions:** `BillingTracker.record/2`, `InvoiceProcessor.mark_paid/2`, `PaymentGateway.apply_refund/2`, `BillingReporter.summary/1`
- **Short explanation:** The responsibility for reading and updating the shared Agent state is spread across four unrelated modules. None of them encapsulates the Agent interaction — they all call `Agent.get/2` and `Agent.update/2` directly, using different data formats (maps, lists, atoms), making the shared state unpredictable and hard to maintain.

---

```elixir
defmodule BillingTracker do
  @moduledoc """
  Records billing events for customer accounts.
  """

  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def record(pid, %{customer_id: _cid, amount: _amt} = entry) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingTracker directly manipulates
    # the Agent state using its own format (prepending a map to a list),
    # bypassing any centralized access layer.
    Agent.update(pid, fn entries ->
      [Map.put(entry, :recorded_at, DateTime.utc_now()) | entries]
    end)
    # VALIDATION: SMELL END
    :ok
  end

  def all_entries(pid) do
    Agent.get(pid, fn entries -> entries end)
  end
end

defmodule InvoiceProcessor do
  @moduledoc """
  Handles invoice state transitions.
  """

  def mark_paid(pid, invoice_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because InvoiceProcessor directly calls
    # Agent.update/2 on the shared PID, adding a completely different
    # structure (a tagged tuple) into the same list managed by BillingTracker.
    Agent.update(pid, fn entries ->
      [{:paid_invoice, invoice_id, DateTime.utc_now()} | entries]
    end)
    # VALIDATION: SMELL END
    :ok
  end

  def pending_invoices(pid) do
    Agent.get(pid, fn entries ->
      Enum.filter(entries, fn
        {:paid_invoice, _, _} -> false
        %{status: :pending} -> true
        _ -> false
      end)
    end)
  end
end

defmodule PaymentGateway do
  @moduledoc """
  Processes payments and refunds via external gateway.
  """

  def apply_refund(pid, %{customer_id: cid, refund_amount: amount}) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because PaymentGateway directly updates the
    # Agent state in its own format (a keyword list), adding yet another
    # shape of data to the shared collection, making the state heterogeneous
    # and fragile.
    Agent.update(pid, fn entries ->
      [[customer_id: cid, refund: amount, applied_at: DateTime.utc_now()] | entries]
    end)
    # VALIDATION: SMELL END
    :ok
  end

  def total_refunded(pid) do
    Agent.get(pid, fn entries ->
      entries
      |> Enum.filter(&is_list/1)
      |> Enum.reduce(Decimal.new(0), fn entry, acc ->
        Decimal.add(acc, Decimal.new(entry[:refund] || 0))
      end)
    end)
  end
end

defmodule BillingReporter do
  @moduledoc """
  Generates billing summaries and audit reports.
  """

  def summary(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingReporter directly reads
    # from the Agent without going through any interface, and must defensively
    # pattern-match against all possible shapes written by the other modules.
    entries = Agent.get(pid, fn entries -> entries end)
    # VALIDATION: SMELL END

    total_billed =
      entries
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(Decimal.new(0), fn %{amount: a}, acc -> Decimal.add(acc, Decimal.new(a)) end)

    paid_count =
      Enum.count(entries, fn
        {:paid_invoice, _, _} -> true
        _ -> false
      end)

    refund_count = Enum.count(entries, &is_list/1)

    %{
      total_billed: total_billed,
      paid_invoices: paid_count,
      refunds_applied: refund_count,
      raw_entry_count: length(entries)
    }
  end

  def audit_log(pid) do
    Agent.get(pid, fn entries ->
      Enum.map(entries, fn entry ->
        case entry do
          %{customer_id: cid} -> "Billing entry for customer #{cid}"
          {:paid_invoice, id, _at} -> "Invoice #{id} marked paid"
          kw when is_list(kw) -> "Refund applied to customer #{kw[:customer_id]}"
          _ -> "Unknown entry"
        end
      end)
    end)
  end
end
```
