## Smell Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `encode_refund_note/1` — the `"#{note}"` string interpolation
- **Affected function(s):** `Payments.RefundProcessor.encode_refund_note/1`
- **Short explanation:** String interpolation `"#{note}"` uses the `String.Chars` protocol internally. The function has no guard clause restricting `note` to protocol-implementing types. Passing a `Map`, `Tuple`, or arbitrary struct without `String.Chars` raises `Protocol.UndefinedError`. Passing numeric or atom values succeeds silently but encodes semantically meaningless refund notes.

```elixir
defmodule Payments.RefundProcessor do
  @moduledoc """
  Handles full and partial refund processing for completed payment transactions.
  Integrates with the payment gateway and writes audit records for compliance.
  """

  alias Payments.{Transaction, Gateway, AuditLog, RefundPolicy}

  @max_note_bytes 512
  @allowed_reasons ~w(duplicate fraudulent requested_by_customer product_not_received other)a

  def process_refund(transaction_id, amount, reason, opts \\ []) do
    note = Keyword.get(opts, :note, "")
    initiator = Keyword.get(opts, :initiated_by, :system)

    with {:ok, transaction} <- Transaction.fetch(transaction_id),
         :ok <- RefundPolicy.check(transaction, amount),
         :ok <- validate_reason(reason),
         {:ok, encoded_note} <- encode_refund_note(note),
         {:ok, gateway_response} <-
           Gateway.issue_refund(transaction.gateway_ref, amount, reason) do
      audit_entry = %{
        transaction_id: transaction_id,
        refund_id: gateway_response.refund_id,
        amount: amount,
        reason: reason,
        note: encoded_note,
        initiated_by: initiator,
        processed_at: DateTime.utc_now()
      }

      AuditLog.write(audit_entry)
      {:ok, gateway_response}
    end
  end

  def validate_reason(reason) when reason in @allowed_reasons, do: :ok
  def validate_reason(reason), do: {:error, {:invalid_refund_reason, reason}}

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because the string interpolation `"#{note}"` uses the
  # VALIDATION: `String.Chars` protocol internally. The function has no guard clause
  # VALIDATION: restricting `note` to types that implement the protocol. A caller passing
  # VALIDATION: a Map (e.g., a structured reason breakdown), Tuple, or PID will crash
  # VALIDATION: with `Protocol.UndefinedError`. Passing a float or integer silently encodes
  # VALIDATION: the note as a raw numeric string, losing intent and bypassing the
  # VALIDATION: byte-length validation in a non-obvious way.
  def encode_refund_note(note) do
    encoded = "#{note}" |> String.trim()

    if byte_size(encoded) > @max_note_bytes do
      {:error, {:note_too_long, byte_size(encoded), @max_note_bytes}}
    else
      {:ok, encoded}
    end
  end
  # VALIDATION: SMELL END

  def partial_refund_amount(%Transaction{} = tx, percentage)
      when is_float(percentage) and percentage > 0.0 and percentage <= 1.0 do
    rounded = tx.amount |> Decimal.mult(Decimal.from_float(percentage)) |> Decimal.round(2)
    {:ok, rounded}
  end

  def partial_refund_amount(_, _), do: {:error, :invalid_percentage}

  def refund_eligible?(%Transaction{status: :completed, refunded: false}), do: true
  def refund_eligible?(_), do: false

  def list_pending_refunds(since \\ nil) do
    cutoff = since || DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
    AuditLog.query_refunds(status: :pending, since: cutoff)
  end

  def reconcile_refunds(refund_ids) when is_list(refund_ids) do
    Enum.reduce(refund_ids, {[], []}, fn id, {ok_acc, err_acc} ->
      case Gateway.check_refund_status(id) do
        {:ok, :settled} -> {[id | ok_acc], err_acc}
        {:ok, :pending} -> {ok_acc, err_acc}
        {:error, reason} -> {ok_acc, [{id, reason} | err_acc]}
      end
    end)
  end

  def format_refund_summary(refund) do
    %{
      refund_id: refund.refund_id,
      transaction_id: refund.transaction_id,
      amount: Decimal.to_string(refund.amount),
      reason: refund.reason,
      note: refund.note,
      processed_at: DateTime.to_iso8601(refund.processed_at)
    }
  end
end
```
