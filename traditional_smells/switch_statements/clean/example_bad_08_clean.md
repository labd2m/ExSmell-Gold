```elixir
defmodule TransactionLedger do
  @moduledoc """
  Manages ledger entries and state transitions for payment transactions.
  Provides querying utilities for reporting, reconciliation, and customer
  support workflows.
  """

  require Logger

  @statuses [:authorized, :captured, :refunded, :voided, :failed]

  def valid_statuses, do: @statuses







  @doc """
  Returns the accounting ledger entry type associated with a transaction status.
  Used when posting double-entry bookkeeping records.
  """
  def ledger_entry_type(%{status: status}) do
    case status do
      :authorized -> :debit_hold
      :captured -> :debit_settled
      :refunded -> :credit
      :voided -> :reversal
      :failed -> :no_entry
      _ -> :unknown
    end
  end

  @doc """
  Returns true when the transaction has reached a status from which no further
  state transitions are possible.
  """
  def is_terminal_status?(%{status: status}) do
    case status do
      :authorized -> false
      :captured -> false
      :refunded -> true
      :voided -> true
      :failed -> true
      _ -> false
    end
  end

  @doc """
  Returns a localized, customer-facing display string for the transaction status.
  """
  def status_display(%{status: status}) do
    case status do
      :authorized -> "Payment Authorized"
      :captured -> "Payment Confirmed"
      :refunded -> "Refund Processed"
      :voided -> "Transaction Voided"
      :failed -> "Payment Failed"
      _ -> "Unknown State"
    end
  end



  @doc """
  Attempts to move a transaction from its current status to the requested status,
  enforcing allowed transition rules.
  """
  def transition(%{status: current} = txn, new_status) do
    if is_terminal_status?(txn) do
      {:error, {:terminal_state, current}}
    else
      allowed_transitions = %{
        authorized: [:captured, :voided],
        captured: [:refunded]
      }

      if new_status in Map.get(allowed_transitions, current, []) do
        updated = %{txn | status: new_status, updated_at: DateTime.utc_now()}
        Logger.info("Transaction #{txn.id} transitioned: #{current} -> #{new_status}")
        {:ok, updated}
      else
        {:error, {:invalid_transition, {current, new_status}}}
      end
    end
  end

  @doc """
  Posts a ledger entry for the transaction to the accounting subsystem.
  Returns the posted entry reference.
  """
  def post_ledger_entry(%{} = txn) do
    entry_type = ledger_entry_type(txn)

    if entry_type == :no_entry do
      Logger.debug("Skipping ledger entry for failed transaction #{txn.id}.")
      {:ok, :skipped}
    else
      entry = %{
        transaction_id: txn.id,
        entry_type: entry_type,
        amount: txn.amount,
        currency: txn.currency,
        posted_at: DateTime.utc_now()
      }

      Logger.info("Posting #{entry_type} ledger entry for #{txn.id}.")
      {:ok, entry}
    end
  end

  @doc """
  Builds a full transaction detail view suitable for a customer support agent.
  """
  def transaction_detail_view(%{} = txn) do
    %{
      id: txn.id,
      status: txn.status,
      status_label: status_display(txn),
      amount: txn.amount,
      currency: txn.currency,
      is_final: is_terminal_status?(txn),
      ledger_type: ledger_entry_type(txn),
      created_at: txn.created_at,
      updated_at: Map.get(txn, :updated_at)
    }
  end

  @doc """
  Reconciles a list of transactions, separating settled from unsettled entries.
  """
  def reconcile(transactions) when is_list(transactions) do
    {settled, unsettled} =
      Enum.split_with(transactions, fn txn ->
        txn.status == :captured
      end)

    total_settled = Enum.reduce(settled, 0, &(&1.amount + &2))
    total_unsettled = Enum.reduce(unsettled, 0, &(&1.amount + &2))

    %{
      settled_count: length(settled),
      unsettled_count: length(unsettled),
      total_settled_amount: total_settled,
      total_unsettled_amount: total_unsettled
    }
  end
end
```
