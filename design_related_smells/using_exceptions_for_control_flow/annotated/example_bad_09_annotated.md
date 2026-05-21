# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Payments.RefundProcessor.process/2`
- **Affected function(s):** `Payments.RefundProcessor.process/2` (library side); `Payments.RefundWorkflow.execute/2` (client side)
- **Explanation:** `process/2` raises `RuntimeError` for expected refund failure conditions: transaction not found, refund window expired, requested amount exceeding the original charge, and duplicate refund. These are routine business-rule violations that a refund workflow must handle gracefully. By raising, the function leaves callers no choice but to use `try/rescue` for normal refund-processing logic.

```elixir
defmodule Payments.Transaction do
  @moduledoc "Represents a completed payment transaction."

  @enforce_keys [:id, :amount, :currency, :status, :charged_at, :customer_id]
  defstruct [
    :id,
    :amount,
    :currency,
    :status,
    :charged_at,
    :customer_id,
    :refunded_amount,
    :metadata
  ]

  def refundable_amount(%__MODULE__{amount: a, refunded_amount: r}), do: a - (r || 0)
  def fully_refunded?(%__MODULE__{} = t), do: refundable_amount(t) == 0
end

defmodule Payments.TransactionStore do
  @moduledoc "In-memory transaction ledger."

  alias Payments.Transaction

  @transactions %{
    "txn_001" => %Transaction{
      id: "txn_001",
      amount: 199.99,
      currency: "USD",
      status: :captured,
      charged_at: DateTime.add(DateTime.utc_now(), -3600, :second),
      customer_id: "cust_1",
      refunded_amount: 0.0
    },
    "txn_002" => %Transaction{
      id: "txn_002",
      amount: 49.0,
      currency: "USD",
      status: :captured,
      charged_at: DateTime.add(DateTime.utc_now(), -86_400 * 60, :second),
      customer_id: "cust_2",
      refunded_amount: 49.0
    }
  }

  def find(id), do: Map.fetch(@transactions, id)

  def record_refund(txn_id, amount) do
    case Map.fetch(@transactions, txn_id) do
      {:ok, txn} ->
        updated = %{txn | refunded_amount: (txn.refunded_amount || 0) + amount}
        {:ok, updated}

      :error ->
        {:error, :not_found}
    end
  end
end

defmodule Payments.GatewayAdapter do
  @moduledoc "Sends refund instructions to the payment gateway."

  def issue_refund(_txn_id, amount) when amount > 0 do
    {:ok, "ref_#{:rand.uniform(9_999_999)}"}
  end
end

defmodule Payments.RefundProcessor do
  @moduledoc """
  Validates refund eligibility and issues refunds through the payment gateway.
  Enforces business rules such as the refund window and partial refund limits.
  """

  alias Payments.{GatewayAdapter, Transaction, TransactionStore}
  require Logger

  @refund_window_days 30

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `process/2` raises RuntimeError for four
  # VALIDATION: predictable, policy-based refund failures: unknown transaction,
  # VALIDATION: expired refund window, over-refund attempt, and duplicate/full refund.
  # VALIDATION: These are not system errors — they are expected policy violations.
  # VALIDATION: Callers processing a refund queue are forced to use try/rescue
  # VALIDATION: simply to know whether a given refund succeeded or why it failed.
  def process(transaction_id, amount) when is_binary(transaction_id) and is_number(amount) do
    case TransactionStore.find(transaction_id) do
      :error ->
        raise RuntimeError,
          message: "Transaction '#{transaction_id}' not found"

      {:ok, txn} ->
        if Transaction.fully_refunded?(txn) do
          raise RuntimeError,
            message: "Transaction '#{transaction_id}' has already been fully refunded"
        end

        age_days = DateTime.diff(DateTime.utc_now(), txn.charged_at, :second) |> div(86_400)

        if age_days > @refund_window_days do
          raise RuntimeError,
            message:
              "Transaction '#{transaction_id}' is #{age_days} days old. " <>
                "Refunds are only accepted within #{@refund_window_days} days of the charge."
        end

        refundable = Transaction.refundable_amount(txn)

        if amount > refundable do
          raise RuntimeError,
            message:
              "Requested refund of #{amount} #{txn.currency} exceeds the refundable " <>
                "balance of #{refundable} #{txn.currency} on transaction '#{transaction_id}'"
        end

        {:ok, refund_id} = GatewayAdapter.issue_refund(transaction_id, amount)
        {:ok, _updated} = TransactionStore.record_refund(transaction_id, amount)

        Logger.info("Refund #{refund_id} issued for txn=#{transaction_id} amount=#{amount}")
        %{refund_id: refund_id, transaction_id: transaction_id, amount: amount}
    end
  end
  # VALIDATION: SMELL END
end

defmodule Payments.RefundWorkflow do
  @moduledoc """
  Executes a refund request originating from customer service or an automated policy.
  Returns a structured outcome suitable for the calling web or background job layer.
  """

  alias Payments.RefundProcessor
  require Logger

  def execute(transaction_id, amount) do
    # Client forced to use try/rescue because RefundProcessor.process/2
    # raises on all policy-failure paths instead of returning {:error, reason}.
    try do
      result = RefundProcessor.process(transaction_id, amount)
      Logger.info("Refund workflow succeeded: #{result.refund_id}")
      {:ok, result}
    rescue
      e in RuntimeError ->
        Logger.warning("Refund workflow failed for txn=#{transaction_id}: #{e.message}")
        {:error, %{transaction_id: transaction_id, reason: e.message}}
    end
  end

  def execute_batch(refund_requests) when is_list(refund_requests) do
    Enum.map(refund_requests, fn %{transaction_id: txn_id, amount: amount} ->
      %{transaction_id: txn_id, result: execute(txn_id, amount)}
    end)
  end
end
```
