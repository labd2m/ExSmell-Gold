```elixir
defmodule Payments.TransactionEvent do
  defstruct [:type, :occurred_at, :actor, :note]

  @type t :: %__MODULE__{
          type: String.t(),
          occurred_at: DateTime.t(),
          actor: String.t(),
          note: String.t() | nil
        }
end

defmodule Payments.Transaction do
  @enforce_keys [:id, :gateway_ref, :amount, :currency, :status, :created_at]
  defstruct [
    :id,
    :gateway_ref,
    :amount,
    :currency,
    :status,
    :created_at,
    :settled_at,
    :merchant_id,
    :payment_method,
    :risk_score,
    :metadata,
    :events
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          gateway_ref: String.t(),
          amount: float(),
          currency: String.t(),
          status: :pending | :settled | :refunded | :disputed | :failed,
          created_at: DateTime.t(),
          settled_at: DateTime.t() | nil,
          merchant_id: String.t(),
          payment_method: map(),
          risk_score: float(),
          metadata: map(),
          events: [Payments.TransactionEvent.t()]
        }
end

defmodule Payments.GatewayLedger do
  @moduledoc "Simulates a gateway transaction ledger query."

  @spec fetch_unsettled(String.t(), Date.t()) :: [Payments.Transaction.t()]
  def fetch_unsettled(gateway_id, %Date{} = since) do
    now = DateTime.utc_now()

    Enum.map(1..80_000, fn n ->
      %Payments.Transaction{
        id: "txn_#{gateway_id}_#{n}",
        gateway_ref: "gw_ref_#{:rand.uniform(999_999_999)}",
        amount: Float.round(:rand.uniform() * 9_999 + 1, 2),
        currency: Enum.random(["USD", "EUR", "GBP", "BRL"]),
        status: Enum.random([:pending, :settled, :refunded]),
        created_at: DateTime.add(now, -:rand.uniform(30) * 86_400, :second),
        settled_at: nil,
        merchant_id: "merch_#{rem(n, 5000) + 1}",
        payment_method: %{
          type: Enum.random(["card", "bank_transfer", "wallet"]),
          last_four: String.pad_leading("#{rem(n, 9999)}", 4, "0"),
          brand: Enum.random(["visa", "mastercard", "amex"]),
          country: Enum.random(["US", "BR", "DE", "GB"])
        },
        risk_score: :rand.uniform(),
        metadata: %{
          order_id: "ORD-#{n}",
          customer_id: "cust_#{rem(n, 200_000)}",
          ip_address: "#{rem(n, 255)}.#{rem(n * 3, 255)}.0.1",
          device_fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
          since: Date.to_iso8601(since)
        },
        events:
          Enum.map(1..5, fn e ->
            %Payments.TransactionEvent{
              type: Enum.random(["initiated", "authorized", "captured", "flagged"]),
              occurred_at: DateTime.add(now, -e * 120, :second),
              actor: "system",
              note: "Event #{e} for transaction #{n}"
            }
          end)
      }
    end)
  end
end

defmodule Payments.SettlementWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:run_settlement, gateway_id, transactions}, state) do
    _settled = Enum.filter(transactions, &(&1.status == :pending))
    {:noreply, [{gateway_id, length(transactions)} | state]}
  end
end

defmodule Payments.ReconciliationServer do
  @moduledoc """
  Coordinates the nightly settlement run for each payment gateway.
  Fetches unsettled transactions and sends them to the settlement worker.
  """

  require Logger

  @spec request_settlement_run(pid(), String.t()) :: :ok
  def request_settlement_run(settlement_pid, gateway_id) do
    since = Date.add(Date.utc_today(), -7)

    Logger.info("Fetching unsettled transactions for gateway #{gateway_id} since #{since}...")

    transactions = Payments.GatewayLedger.fetch_unsettled(gateway_id, since)

    Logger.info(
      "Loaded #{length(transactions)} transactions. Submitting to settlement worker..."
    )

    send(settlement_pid, {:run_settlement, gateway_id, transactions})

    Logger.info("Settlement run request submitted for gateway #{gateway_id}.")
    :ok
  end
end
```
