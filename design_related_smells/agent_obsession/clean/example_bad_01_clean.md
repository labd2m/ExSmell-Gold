```elixir
defmodule BillingTracker do
  @moduledoc """
  Records billing events for customer accounts.
  """

  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def record(pid, %{customer_id: _cid, amount: _amt} = entry) do
    Agent.update(pid, fn entries ->
      [Map.put(entry, :recorded_at, DateTime.utc_now()) | entries]
    end)
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
    Agent.update(pid, fn entries ->
      [{:paid_invoice, invoice_id, DateTime.utc_now()} | entries]
    end)
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
    Agent.update(pid, fn entries ->
      [[customer_id: cid, refund: amount, applied_at: DateTime.utc_now()] | entries]
    end)
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
    entries = Agent.get(pid, fn entries -> entries end)

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
