# Annotated Example 06 — Large Messages

| Field                  | Value                                                                         |
|------------------------|-------------------------------------------------------------------------------|
| **Smell name**         | Large messages                                                                |
| **Expected location**  | `Payments.ReportDispatcher.generate_report/3`                                |
| **Affected function(s)**| `generate_report/3`, `handle_cast/2` (GenServer)                            |
| **Explanation**        | A full history of payment transaction records — potentially covering months of activity with thousands of entries — is fetched in the dispatcher process and then sent in one `GenServer.cast` to the reporting worker. Each transaction record carries nested card data, metadata, and webhook payload snapshots. Copying all of this between processes at report-generation time is slow and blocks the dispatcher, causing queued report requests to wait longer than necessary. |

```elixir
defmodule Payments.CardInfo do
  defstruct [:brand, :last_four, :exp_month, :exp_year, :funding, :country]
end

defmodule Payments.WebhookPayload do
  defstruct [:event_type, :received_at, :raw_body, :headers, :verified]
end

defmodule Payments.Transaction do
  @enforce_keys [:id, :account_id, :amount_cents, :currency, :status, :created_at]
  defstruct [
    :id,
    :account_id,
    :amount_cents,
    :currency,
    :status,
    :created_at,
    :settled_at,
    :card,
    :description,
    :idempotency_key,
    :gateway_response,
    :webhook_payload,
    :fee_cents,
    :metadata
  ]
end

defmodule Payments.TransactionRepo do
  @moduledoc "Simulates fetching transactions from persistence."

  @spec list_for_period(String.t(), Date.t(), Date.t()) :: list(Payments.Transaction.t())
  def list_for_period(account_id, _date_from, _date_to) do
    Enum.map(1..20_000, fn i ->
      %Payments.Transaction{
        id: "TXN-#{account_id}-#{i}",
        account_id: account_id,
        amount_cents: Enum.random(100..500_000),
        currency: "BRL",
        status: Enum.random([:captured, :refunded, :disputed, :failed]),
        created_at: DateTime.utc_now(),
        settled_at: DateTime.utc_now(),
        card: %Payments.CardInfo{
          brand: "visa",
          last_four: String.pad_leading("#{rem(i, 10_000)}", 4, "0"),
          exp_month: 12,
          exp_year: 2027,
          funding: "credit",
          country: "BR"
        },
        description: "Purchase at Merchant #{rem(i, 500)}",
        idempotency_key: "idem-#{i}-#{account_id}",
        gateway_response: %{
          gateway: "stripe",
          charge_id: "ch_#{i}",
          network_transaction_id: "nw_#{i}",
          avs_result: "Y",
          cvv_result: "M"
        },
        webhook_payload: %Payments.WebhookPayload{
          event_type: "payment_intent.succeeded",
          received_at: DateTime.utc_now(),
          raw_body: "{\"id\":\"pi_#{i}\",\"amount\":#{i * 100}}",
          headers: %{"stripe-signature" => "t=#{i},v1=abc#{i}"},
          verified: true
        },
        fee_cents: div(i * 100, 100) + 30,
        metadata: %{
          order_id: "ORD-#{i}",
          customer_email: "cust#{rem(i, 1_000)}@example.com",
          source: "web_checkout"
        }
      }
    end)
  end
end

defmodule Payments.ReportWorker do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{reports: []}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:build_report, account_id, transactions}, state) do
    total = Enum.sum(Enum.map(transactions, & &1.amount_cents))
    fees = Enum.sum(Enum.map(transactions, & &1.fee_cents))
    count = length(transactions)

    report = %{
      account_id: account_id,
      total_amount_cents: total,
      total_fees_cents: fees,
      transaction_count: count,
      generated_at: DateTime.utc_now()
    }

    {:noreply, %{state | reports: [report | state.reports]}}
  end

  @impl true
  def handle_call(:list_reports, _from, state) do
    {:reply, state.reports, state}
  end
end

defmodule Payments.ReportDispatcher do
  @moduledoc "Fetches payment data and dispatches report generation to worker processes."

  require Logger

  @spec generate_report(pid(), String.t(), {Date.t(), Date.t()}) :: :ok
  def generate_report(worker_pid, account_id, {date_from, date_to}) do
    Logger.info("Fetching transactions for account #{account_id}")

    transactions = Payments.TransactionRepo.list_for_period(account_id, date_from, date_to)

    Logger.info("Sending #{length(transactions)} transactions to report worker")

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `transactions` is a list of 20 000
    # Transaction structs, each containing a CardInfo struct, a map for
    # gateway_response, a WebhookPayload struct (including a raw_body binary
    # and a headers map), and a metadata map. Casting the entire collection
    # to the ReportWorker in a single message causes a full heap copy of all
    # this data. The dispatcher is blocked throughout the copy, and when
    # concurrent report requests for different accounts are dispatched, the
    # cumulative blocking degrades overall throughput significantly.
    GenServer.cast(worker_pid, {:build_report, account_id, transactions})
    # VALIDATION: SMELL END

    :ok
  end
end
```
