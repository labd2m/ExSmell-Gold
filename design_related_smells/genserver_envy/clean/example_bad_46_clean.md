```elixir
defmodule PaymentLedger do
  @moduledoc """
  Maintains an in-process ledger of payment transactions for a merchant.
  Supports authorization holds, captures, refunds, and settlement runs.
  """

  use Agent

  require Logger

  @type transaction :: %{
          id: String.t(),
          merchant_id: String.t(),
          amount: float(),
          currency: String.t(),
          status: :pending | :captured | :refunded | :failed | :flagged,
          method: :card | :bank | :wallet,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{transactions: %{}, balance: 0.0} end, name: __MODULE__)
  end

  @doc "Records a new payment transaction."
  def record_transaction(%{id: id} = txn) do
    Agent.update(__MODULE__, fn state ->
      %{state | transactions: Map.put(state.transactions, id, txn)}
    end)
  end

  @doc "Updates the status of an existing transaction."
  def update_status(txn_id, new_status) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :transactions, fn txns ->
        Map.update!(txns, txn_id, fn txn ->
          %{txn | status: new_status, updated_at: DateTime.utc_now()}
        end)
      end)
    end)
  end

  @doc "Returns a transaction by ID."
  def get_transaction(txn_id) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.transactions, txn_id)
    end)
  end


  @doc "Reconciles captured transactions against an expected total — isolated task."
  def reconcile_transactions(merchant_id) do
    Agent.get(__MODULE__, fn state ->
      captured =
        state.transactions
        |> Map.values()
        |> Enum.filter(&(&1.merchant_id == merchant_id and &1.status == :captured))

      total_captured =
        captured
        |> Enum.map(& &1.amount)
        |> Enum.sum()
        |> Float.round(2)

      by_currency =
        captured
        |> Enum.group_by(& &1.currency)
        |> Enum.map(fn {currency, txns} ->
          {currency, txns |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(2)}
        end)
        |> Map.new()

      %{
        merchant_id: merchant_id,
        transaction_count: length(captured),
        total_captured: total_captured,
        by_currency: by_currency,
        reconciled_at: DateTime.utc_now()
      }
    end)
  end

  @doc "Generates a settlement summary for a merchant — isolated task."
  def generate_settlement(merchant_id) do
    Agent.get(__MODULE__, fn state ->
      eligible =
        state.transactions
        |> Map.values()
        |> Enum.filter(fn t ->
          t.merchant_id == merchant_id and t.status == :captured
        end)

      if Enum.empty?(eligible) do
        {:error, :no_eligible_transactions}
      else
        gross = eligible |> Enum.map(& &1.amount) |> Enum.sum()
        fee = Float.round(gross * 0.029 + length(eligible) * 0.30, 2)
        net = Float.round(gross - fee, 2)

        {:ok,
         %{
           settlement_id: "STL-#{:erlang.unique_integer([:positive])}",
           merchant_id: merchant_id,
           transaction_ids: Enum.map(eligible, & &1.id),
           gross_amount: Float.round(gross, 2),
           processing_fee: fee,
           net_payout: net,
           currency: "USD",
           generated_at: DateTime.utc_now()
         }}
      end
    end)
  end

  @doc "Flags transactions that exceed a threshold as suspicious — isolated task."
  def flag_suspicious(merchant_id, threshold) do
    Agent.get_and_update(__MODULE__, fn state ->
      {flagged_ids, updated_txns} =
        state.transactions
        |> Enum.reduce({[], state.transactions}, fn {id, txn}, {flags, txns} ->
          if txn.merchant_id == merchant_id and
               txn.status == :pending and
               txn.amount > threshold do
            Logger.warning("[PaymentLedger] Flagging suspicious txn #{id}: $#{txn.amount}")
            updated_txn = %{txn | status: :flagged, updated_at: DateTime.utc_now()}
            {[id | flags], Map.put(txns, id, updated_txn)}
          else
            {flags, txns}
          end
        end)

      result = %{
        flagged_count: length(flagged_ids),
        flagged_ids: Enum.reverse(flagged_ids),
        threshold: threshold
      }

      {result, %{state | transactions: updated_txns}}
    end)
  end


  @doc "Returns the current ledger balance."
  def get_balance do
    Agent.get(__MODULE__, & &1.balance)
  end

  @doc "Lists all transactions for a merchant."
  def list_transactions(merchant_id) do
    Agent.get(__MODULE__, fn state ->
      state.transactions
      |> Map.values()
      |> Enum.filter(&(&1.merchant_id == merchant_id))
    end)
  end
end
```
