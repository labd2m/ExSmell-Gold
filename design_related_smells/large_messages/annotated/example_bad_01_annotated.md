# Annotated Example 01 — Large Messages

| Field                  | Value                                                                 |
|------------------------|-----------------------------------------------------------------------|
| **Smell name**         | Large messages                                                        |
| **Expected location**  | `BillingAggregator.request_monthly_report/2`                         |
| **Affected function(s)**| `request_monthly_report/2`, `handle_info/2` (GenServer)             |
| **Explanation**        | The entire list of invoice records (potentially tens of thousands of entries) is fetched in the caller process and then sent as a single message to the `BillingAggregator` GenServer. Copying this large structure across process boundaries blocks the sender and strains the scheduler, especially when called frequently at month-end batch time. |

```elixir
defmodule Billing.Invoice do
  @moduledoc "Represents a single invoice record."

  @enforce_keys [:id, :customer_id, :amount_cents, :issued_at, :line_items]
  defstruct [:id, :customer_id, :amount_cents, :issued_at, :status, :line_items, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          amount_cents: non_neg_integer(),
          issued_at: DateTime.t(),
          status: :paid | :pending | :overdue,
          line_items: list(map()),
          metadata: map()
        }
end

defmodule Billing.InvoiceStore do
  @moduledoc "Simulates fetching invoices from a data store."

  @spec fetch_for_month(integer(), integer()) :: list(Billing.Invoice.t())
  def fetch_for_month(year, month) do
    # Simulates returning a large number of invoice structs from the DB
    Enum.map(1..25_000, fn i ->
      %Billing.Invoice{
        id: "INV-#{year}-#{month}-#{i}",
        customer_id: "CUST-#{rem(i, 5_000)}",
        amount_cents: Enum.random(500..500_000),
        issued_at: DateTime.utc_now(),
        status: Enum.random([:paid, :pending, :overdue]),
        line_items: Enum.map(1..10, fn j ->
          %{sku: "SKU-#{j}", qty: j, unit_price: j * 100}
        end),
        metadata: %{
          source: "erp",
          batch_id: "BATCH-#{i}",
          tags: ["monthly", "auto-generated"]
        }
      }
    end)
  end
end

defmodule Billing.BillingAggregator do
  @moduledoc """
  GenServer that receives monthly invoice batches and computes
  aggregated billing statistics per customer.
  """
  use GenServer

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @spec request_monthly_report(pid(), list(Billing.Invoice.t())) :: :ok
  def request_monthly_report(server, invoices) do
    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `invoices` is a list of up to 25 000
    # fully-populated Invoice structs (each with 10 line_item maps and a
    # metadata map). The entire structure is copied from the calling process
    # into the GenServer's mailbox in one shot, blocking the sender for a
    # significant amount of time and potentially overwhelming the mailbox when
    # this function is called concurrently by multiple month-end batch jobs.
    send(server, {:process_invoices, invoices})
    # VALIDATION: SMELL END
    :ok
  end

  # --- Server callbacks ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:process_invoices, invoices}, state) do
    aggregated =
      invoices
      |> Enum.group_by(& &1.customer_id)
      |> Enum.map(fn {customer_id, inv_list} ->
        total = Enum.sum(Enum.map(inv_list, & &1.amount_cents))
        count = length(inv_list)
        {customer_id, %{total_cents: total, invoice_count: count}}
      end)
      |> Map.new()

    new_state = Map.merge(state, aggregated)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_report, _from, state) do
    {:reply, state, state}
  end
end

defmodule Billing.MonthEndRunner do
  @moduledoc "Orchestrates the month-end billing aggregation pipeline."

  require Logger

  @spec run(integer(), integer()) :: :ok
  def run(year, month) do
    Logger.info("Starting month-end billing run for #{year}-#{month}")

    {:ok, aggregator} = Billing.BillingAggregator.start_link()

    # Fetch the full invoice dataset in the calling process …
    invoices = Billing.InvoiceStore.fetch_for_month(year, month)

    Logger.info("Fetched #{length(invoices)} invoices — dispatching to aggregator")

    # … then ship the entire list across the process boundary.
    Billing.BillingAggregator.request_monthly_report(aggregator, invoices)

    Process.sleep(500)

    report = GenServer.call(aggregator, :get_report)
    Logger.info("Aggregation complete. Customers processed: #{map_size(report)}")

    :ok
  end
end
```
