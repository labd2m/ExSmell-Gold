# Annotated Example – Bad Code (Human Validation)

## Metadata

- **Smell name:** Large messages
- **Expected smell location:** `BillingExporter.export_monthly_report/2` — the call to `send/2` that dispatches a full invoice dataset to the reporter process
- **Affected function(s):** `BillingExporter.export_monthly_report/2`, `BillingReporter.handle_info/2`
- **Short explanation:** The entire list of invoice records — potentially tens of thousands of maps — is serialised and copied in a single message from the exporter process to the reporter process. This large copy blocks the sender and can degrade system throughput when called repeatedly at month-end.

---

```elixir
defmodule BillingReporter do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{reports: []}, opts)
  end

  def get_reports(pid) do
    GenServer.call(pid, :get_reports)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_reports, _from, state) do
    {:reply, state.reports, state}
  end

  @impl true
  def handle_info({:billing_report, tenant_id, invoices}, state) do
    Logger.info("BillingReporter received report for tenant=#{tenant_id} with #{length(invoices)} invoices")

    summary = %{
      tenant_id: tenant_id,
      total_invoices: length(invoices),
      total_amount: Enum.reduce(invoices, Decimal.new(0), fn inv, acc ->
        Decimal.add(acc, inv.amount)
      end),
      received_at: DateTime.utc_now()
    }

    updated_reports = [summary | state.reports]
    {:noreply, %{state | reports: updated_reports}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

defmodule BillingExporter do
  require Logger

  @doc """
  Loads all invoices for the given tenant and billing period from the
  repository, then ships the full dataset to the reporter process so it
  can compute summaries and persist audit records.
  """
  def export_monthly_report(reporter_pid, tenant_id) do
    Logger.info("Starting monthly export for tenant=#{tenant_id}")

    invoices = fetch_all_invoices(tenant_id)

    Logger.info("Fetched #{length(invoices)} invoices — sending to reporter")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because the full list of invoice structs
    # (potentially tens of thousands of records, each with nested maps) is
    # deep-copied into the reporter process's mailbox in a single send/2 call.
    # The sender is blocked until the copy completes, and if this export runs
    # for many tenants concurrently the copying pressure degrades throughput.
    send(reporter_pid, {:billing_report, tenant_id, invoices})
    # VALIDATION: SMELL END

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate fetching a large dataset from a data store
  # ---------------------------------------------------------------------------

  defp fetch_all_invoices(tenant_id) do
    Enum.map(1..15_000, fn n ->
      %{
        id: "INV-#{tenant_id}-#{String.pad_leading(Integer.to_string(n), 8, "0")}",
        tenant_id: tenant_id,
        customer_id: "CUST-#{:rand.uniform(5_000)}",
        line_items: build_line_items(),
        amount: Decimal.new("#{:rand.uniform(9_999)}.#{:rand.uniform(99)}"),
        currency: "USD",
        status: Enum.random([:paid, :pending, :overdue]),
        issued_at: ~U[2024-01-01 00:00:00Z],
        due_at: ~U[2024-01-31 00:00:00Z],
        metadata: %{
          source: "stripe",
          idempotency_key: "idem-#{n}",
          tags: ["auto-generated", "monthly", "batch"]
        }
      }
    end)
  end

  defp build_line_items do
    Enum.map(1..:rand.uniform(10), fn i ->
      %{
        description: "Service line #{i}",
        unit_price: Decimal.new("#{:rand.uniform(500)}.00"),
        quantity: :rand.uniform(20),
        tax_rate: Decimal.new("0.08")
      }
    end)
  end
end
```
