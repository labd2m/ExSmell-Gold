```elixir
defmodule Payments.RefundEngine do
  @moduledoc """
  Processes refunds for completed transactions. Handles full and partial
  refunds, coordinates with the payment gateway, and maintains a full
  audit trail for finance reconciliation.
  """

  alias Payments.{Transaction, Refund, RefundLog, Gateway}
  alias Payments.Repo

  @max_refund_window_days 90

  def initiate_refund(transaction_id, amount, reason \\ :customer_request) do
    transaction = Repo.get!(Transaction, transaction_id)

    with :ok <- validate_refundable(transaction),
         :ok <- validate_refund_amount(transaction, amount),
         :ok <- within_refund_window?(transaction) do
      case Gateway.refund(transaction.gateway_ref, amount) do
        {:ok, refund_ref} ->
          record_refund(transaction, refund_ref, amount, reason)

        {:error, gateway_reason} ->
          log_failed_refund(transaction_id, amount, gateway_reason)
          {:error, gateway_reason}
      end
    end
  end

  def process_full_refund(transaction_id) do
    transaction = Repo.get!(Transaction, transaction_id)
    initiate_refund(transaction_id, transaction.amount)
  end

  def process_partial_refund(transaction_id, amount) do
    initiate_refund(transaction_id, amount)
  end

  def handle_dispute(transaction_id, dispute_ref) do
    transaction = Repo.get!(Transaction, transaction_id)

    case initiate_refund(transaction_id, transaction.amount) do
      {:ok, refund} ->
        transaction
        |> Transaction.changeset(%{
          status:           :disputed_refunded,
          dispute_ref:      dispute_ref,
          dispute_resolved: true
        })
        |> Repo.update()

        {:ok, refund}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_refund(refund_id) do
    refund = Repo.get!(Refund, refund_id)

    if refund.status != :pending do
      {:error, :not_cancellable}
    else
      case Gateway.cancel_refund(refund.gateway_refund_ref) do
        :ok ->
          refund
          |> Refund.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def refund_history(transaction_id) do
    Refund
    |> Repo.all()
    |> Enum.filter(&(&1.transaction_id == transaction_id))
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  def total_refunded(transaction_id) do
    Refund
    |> Repo.all()
    |> Enum.filter(&(&1.transaction_id == transaction_id and &1.status == :completed))
    |> Enum.reduce(0.0, fn r, acc -> acc + r.amount end)
    |> Float.round(2)
  end

  def refund_report(from_dt, to_dt) do
    Refund
    |> Repo.all()
    |> Enum.filter(fn r ->
      DateTime.compare(r.created_at, from_dt) in [:gt, :eq] and
        DateTime.compare(r.created_at, to_dt) in [:lt, :eq]
    end)
    |> Enum.reduce(%{count: 0, total: 0.0, by_reason: %{}}, fn r, acc ->
      by_reason = Map.update(acc.by_reason, r.reason, r.amount, &(&1 + r.amount))
      %{acc | count: acc.count + 1, total: acc.total + r.amount, by_reason: by_reason}
    end)
    |> Map.update!(:total, &Float.round(&1, 2))
  end


  defp validate_refundable(%Transaction{status: :completed}), do: :ok
  defp validate_refundable(_), do: {:error, :transaction_not_refundable}

  defp validate_refund_amount(transaction, amount) do
    already_refunded = total_refunded(transaction.id)
    remaining        = transaction.amount - already_refunded

    if amount > remaining do
      {:error, :exceeds_refundable_amount}
    else
      :ok
    end
  end

  defp within_refund_window?(transaction) do
    cutoff = DateTime.add(DateTime.utc_now(), -@max_refund_window_days * 86_400, :second)

    if DateTime.compare(transaction.created_at, cutoff) == :gt do
      :ok
    else
      {:error, :refund_window_expired}
    end
  end

  defp record_refund(transaction, gateway_ref, amount, reason) do
    attrs = %{
      transaction_id:      transaction.id,
      gateway_refund_ref:  gateway_ref,
      amount:              amount,
      reason:              reason,
      status:              :completed,
      created_at:          DateTime.utc_now()
    }

    case Refund.changeset(%Refund{}, attrs) |> Repo.insert() do
      {:ok, refund} -> {:ok, refund}
      {:error, cs}  -> {:error, cs}
    end
  end

  defp log_failed_refund(transaction_id, amount, reason) do
    Repo.insert!(%RefundLog{
      transaction_id: transaction_id,
      amount:         amount,
      failure_reason: inspect(reason),
      logged_at:      DateTime.utc_now()
    })
  end
end
```
