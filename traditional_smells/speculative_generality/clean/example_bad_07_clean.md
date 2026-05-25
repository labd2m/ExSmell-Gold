```elixir
defmodule Payments.ChargeExecutor do
  @moduledoc """
  Executes payment charges against the configured payment gateway.
  Handles retries, idempotency keys, and charge audit logging for
  all transaction types processed by the billing pipeline.
  """

  alias Payments.{Charge, Transaction, Gateway, AuditLog}
  alias Payments.Repo

  @max_retries    2
  @idempotency_ns "payments"

  def execute_charge(%Charge{} = charge) do
    idempotency_key = build_idempotency_key(charge)

    result =
      case charge.payment_type do
        :credit_card   -> Gateway.charge(charge.amount, idempotency_key)
        :debit_card    -> Gateway.charge(charge.amount, idempotency_key)
        :bank_transfer -> Gateway.charge(charge.amount, idempotency_key)
        _              -> Gateway.charge(charge.amount, idempotency_key)
      end

    case result do
      {:ok, gateway_ref} ->
        record_transaction(charge, gateway_ref, :success)
        {:ok, gateway_ref}

      {:error, reason} ->
        record_transaction(charge, nil, :failed)
        {:error, reason}
    end
  end

  def execute_with_retry(%Charge{} = charge) do
    Enum.reduce_while(1..@max_retries, {:error, :not_attempted}, fn attempt, _acc ->
      case execute_charge(charge) do
        {:ok, ref} ->
          {:halt, {:ok, ref}}

        {:error, reason} ->
          log_retry(charge.id, attempt, reason)

          if attempt < @max_retries do
            Process.sleep(attempt * 1_000)
            {:cont, {:error, reason}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
  end

  def void_charge(transaction_id) do
    transaction = Repo.get!(Transaction, transaction_id)

    case Gateway.void(transaction.gateway_ref) do
      {:ok, void_ref} ->
        transaction
        |> Transaction.changeset(%{
          status:    :voided,
          void_ref:  void_ref,
          voided_at: DateTime.utc_now()
        })
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refund_charge(transaction_id, amount) do
    transaction = Repo.get!(Transaction, transaction_id)

    if amount > transaction.amount do
      {:error, :refund_exceeds_charge}
    else
      case Gateway.refund(transaction.gateway_ref, amount) do
        {:ok, refund_ref} ->
          record_refund(transaction, refund_ref, amount)
          {:ok, refund_ref}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def list_failed_charges(since) do
    Transaction
    |> Repo.all()
    |> Enum.filter(fn t ->
      t.status == :failed and
        DateTime.compare(t.created_at, since) in [:gt, :eq]
    end)
  end

  def charge_summary_for_period(from_dt, to_dt) do
    Transaction
    |> Repo.all()
    |> Enum.filter(fn t ->
      DateTime.compare(t.created_at, from_dt) in [:gt, :eq] and
        DateTime.compare(t.created_at, to_dt) in [:lt, :eq]
    end)
    |> Enum.reduce(%{success: 0, failed: 0, total_charged: 0.0}, fn t, acc ->
      case t.status do
        :success -> %{acc | success: acc.success + 1, total_charged: acc.total_charged + t.amount}
        :failed  -> %{acc | failed: acc.failed + 1}
        _        -> acc
      end
    end)
    |> Map.update!(:total_charged, &Float.round(&1, 2))
  end


  defp build_idempotency_key(charge) do
    "#{@idempotency_ns}:#{charge.order_id}:#{charge.id}"
  end

  defp record_transaction(charge, gateway_ref, status) do
    attrs = %{
      charge_id:   charge.id,
      order_id:    charge.order_id,
      amount:      charge.amount,
      gateway_ref: gateway_ref,
      status:      status,
      created_at:  DateTime.utc_now()
    }

    Transaction.changeset(%Transaction{}, attrs) |> Repo.insert!()
  end

  defp record_refund(transaction, refund_ref, amount) do
    AuditLog.record!(:refund, %{
      transaction_id: transaction.id,
      refund_ref:     refund_ref,
      amount:         amount,
      recorded_at:    DateTime.utc_now()
    })
  end

  defp log_retry(charge_id, attempt, reason) do
    AuditLog.record!(:charge_retry, %{charge_id: charge_id, attempt: attempt, reason: reason})
  end
end
```
