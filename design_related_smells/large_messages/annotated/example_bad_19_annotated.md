# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `InvoiceAggregator.dispatch_monthly_summary/2` |
| **Affected function(s)** | `dispatch_monthly_summary/2` |
| **Short explanation** | The function fetches every invoice line-item for every customer for the entire month and sends the resulting large list as a single message to the report worker process. This forces a full deep copy of a potentially enormous data structure across process boundaries, blocking the sender for the duration of the copy and saturating the message queue of the receiver. |

```elixir
defmodule Billing.Invoice do
  @moduledoc """
  Represents a single invoice issued to a customer.
  """

  @enforce_keys [:id, :customer_id, :issued_at, :due_at, :line_items, :status]
  defstruct [:id, :customer_id, :issued_at, :due_at, :notes, :line_items, :status, :currency]

  @type line_item :: %{
          description: String.t(),
          quantity: non_neg_integer(),
          unit_price: float(),
          tax_rate: float(),
          discount: float()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          issued_at: DateTime.t(),
          due_at: DateTime.t(),
          notes: String.t() | nil,
          line_items: [line_item()],
          status: :paid | :pending | :overdue | :cancelled,
          currency: String.t()
        }
end

defmodule Billing.InvoiceStore do
  @moduledoc """
  Simulated persistent store for invoices.
  In production this would query a database.
  """

  @spec fetch_for_month(Date.t()) :: [Billing.Invoice.t()]
  def fetch_for_month(%Date{} = month_start) do
    month_end = Date.end_of_month(month_start)

    # Simulates returning every invoice (with all line items) for the given month.
    # In a real system this could be tens of thousands of records, each with
    # dozens of line items containing nested maps.
    Enum.map(1..5_000, fn n ->
      %Billing.Invoice{
        id: "INV-#{n}-#{month_start.year}#{month_start.month}",
        customer_id: "CUST-#{rem(n, 800) + 1}",
        issued_at: DateTime.new!(month_start, ~T[09:00:00]),
        due_at: DateTime.new!(month_end, ~T[23:59:59]),
        notes: "Auto-generated invoice for billing cycle #{month_start.year}-#{month_start.month}",
        line_items:
          Enum.map(1..20, fn i ->
            %{
              description: "Service line #{i} – subscription tier #{rem(i, 4) + 1}",
              quantity: Enum.random(1..50),
              unit_price: :rand.uniform() * 500,
              tax_rate: 0.15,
              discount: if(rem(i, 5) == 0, do: 0.10, else: 0.0)
            }
          end),
        status: Enum.random([:paid, :pending, :overdue]),
        currency: "USD"
      }
    end)
  end
end

defmodule Billing.ReportWorker do
  @moduledoc """
  GenServer that receives billing data and produces summary reports.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:monthly_invoices, month, invoices}, state) do
    summary = compute_summary(invoices)
    new_state = Map.put(state, month, summary)
    {:noreply, new_state}
  end

  defp compute_summary(invoices) do
    Enum.reduce(invoices, %{total: 0.0, paid: 0, pending: 0, overdue: 0}, fn inv, acc ->
      subtotal =
        Enum.reduce(inv.line_items, 0.0, fn item, s ->
          s + item.quantity * item.unit_price * (1 - item.discount) * (1 + item.tax_rate)
        end)

      acc
      |> Map.update!(:total, &(&1 + subtotal))
      |> Map.update!(inv.status, &(&1 + 1))
    end)
  end
end

defmodule Billing.InvoiceAggregator do
  @moduledoc """
  Coordinates the monthly invoice summarisation pipeline.
  Fetches all invoices for a billing period and forwards them
  to the report worker for aggregation.
  """

  require Logger

  @doc """
  Fetches the complete invoice dataset for `month_start` and ships the entire
  collection as a single process message to the given `worker_pid`.
  """
  @spec dispatch_monthly_summary(pid(), Date.t()) :: :ok
  def dispatch_monthly_summary(worker_pid, %Date{} = month_start) do
    Logger.info("Fetching all invoices for #{month_start}...")

    invoices = Billing.InvoiceStore.fetch_for_month(month_start)

    Logger.info("Fetched #{length(invoices)} invoices. Dispatching to report worker...")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `invoices` is a list that may contain
    # thousands of deeply nested structs (each with 20 line-item maps). Sending
    # this entire structure as a single message forces the BEAM to deep-copy every
    # byte across process heaps, blocking the sending process for the duration of
    # the copy and potentially overwhelming the receiver's mailbox.
    send(worker_pid, {:monthly_invoices, month_start, invoices})
    # VALIDATION: SMELL END

    Logger.info("Dispatch complete for #{month_start}.")
    :ok
  end

  @doc """
  Runs the full monthly pipeline: starts a worker, dispatches data, and awaits
  completion. Entry-point used by scheduled jobs.
  """
  @spec run_pipeline(Date.t()) :: :ok | {:error, term()}
  def run_pipeline(%Date{} = month_start) do
    case Billing.ReportWorker.start_link(name: nil) do
      {:ok, pid} ->
        dispatch_monthly_summary(pid, month_start)

      {:error, reason} ->
        Logger.error("Failed to start report worker: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```
