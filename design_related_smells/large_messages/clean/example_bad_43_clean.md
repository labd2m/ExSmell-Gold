```elixir
defmodule LedgerAuditor do
  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{audits: [], discrepancies: 0}, opts)
  end

  def discrepancy_count(pid), do: GenServer.call(pid, :discrepancy_count)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:discrepancy_count, _from, state) do
    {:reply, state.discrepancies, state}
  end

  @impl true
  def handle_info({:reconcile, provider, transactions}, state) do
    Logger.info("LedgerAuditor: auditing #{length(transactions)} txns for provider=#{provider}")

    discrepancies =
      Enum.count(transactions, fn txn ->
        Decimal.compare(txn.reported_amount, txn.settled_amount) != :eq
      end)

    audit_record = %{
      provider: provider,
      total: length(transactions),
      discrepancies: discrepancies,
      audited_at: DateTime.utc_now()
    }

    Logger.warn("LedgerAuditor: found #{discrepancies} discrepancies for provider=#{provider}")

    {:noreply, %{state |
      audits: [audit_record | state.audits],
      discrepancies: state.discrepancies + discrepancies
    }}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule ReconciliationRunner do
  require Logger

  @doc """
  Fetches all transactions processed by a payment provider within the given
  date window, then forwards the full dataset to the ledger auditor process
  for discrepancy detection and audit trail creation.
  """
  def run(auditor_pid, provider) do
    Logger.info("ReconciliationRunner: fetching transactions for provider=#{provider}")

    transactions = fetch_transactions(provider)

    Logger.info("ReconciliationRunner: #{length(transactions)} transactions fetched")

    send(auditor_pid, {:reconcile, provider, transactions})

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers — simulate fetching large transaction datasets
  # ---------------------------------------------------------------------------

  defp fetch_transactions(provider) do
    Enum.map(1..80_000, fn n ->
      reported = Decimal.new("#{:rand.uniform(9_999)}.#{:rand.uniform(99)}")
      delta = if rem(n, 500) == 0, do: Decimal.new("0.01"), else: Decimal.new("0")

      %{
        id: "TXN-#{provider}-#{String.pad_leading(Integer.to_string(n), 10, "0")}",
        provider: provider,
        external_ref: "ext-#{:rand.uniform(1_000_000)}",
        type: Enum.random([:charge, :refund, :chargeback, :payout]),
        currency: "USD",
        reported_amount: reported,
        settled_amount: Decimal.add(reported, delta),
        fee_breakdown: %{
          interchange: Decimal.new("0.10"),
          processing: Decimal.new("0.05"),
          network: Decimal.new("0.02")
        },
        card_network: Enum.random(["visa", "mastercard", "amex"]),
        merchant_id: "MID-#{:rand.uniform(10_000)}",
        processed_at: DateTime.add(~U[2024-06-01 00:00:00Z], n * 3, :second),
        metadata: %{
          batch_id: "BATCH-#{div(n, 1_000)}",
          pos_entry_mode: "chip",
          auth_code: "AUTH#{:rand.uniform(999_999)}"
        }
      }
    end)
  end
end
```
