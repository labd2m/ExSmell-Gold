# example_bad_11_clean

```elixir
defmodule Payments.RefundProcessor do
  @moduledoc """
  Handles full and partial refund requests against previously captured charges.
  Coordinates with the payment gateway, updates the ledger, and notifies the customer.
  """

  alias Payments.PaymentGateway
  alias Payments.LedgerWriter
  alias Payments.ChargeStore
  alias Notifications.EmailDispatcher

  @refund_reasons ~w(duplicate fraudulent requested_by_customer product_not_received)
  @default_reason "requested_by_customer"

  def process_refund(refund_request, operator_id) do
    charge_id = Map.fetch!(refund_request, :charge_id)

    with {:ok, charge} <- ChargeStore.fetch(charge_id),
         :ok <- assert_charge_capturable(charge),
         {:ok, payload} <- build_refund_payload(refund_request, charge, operator_id),
         {:ok, gateway_resp} <- PaymentGateway.refund(charge.gateway_ref, payload, operator_id),
         :ok <- LedgerWriter.record_refund(charge, payload, gateway_resp),
         :ok <- EmailDispatcher.send_refund_confirmation(charge.customer_email, gateway_resp) do
      {:ok,
       %{
         refund_id: gateway_resp.refund_id,
         charge_id: charge_id,
         refunded_amount: payload.amount,
         currency: charge.currency,
         status: gateway_resp.status
       }}
    end
  end

  defp build_refund_payload(refund_request, charge, operator_id) do
    refund_amount = Map.get(refund_request, :amount, charge.amount)
    reason = Map.get(refund_request, :reason, @default_reason)
    note = Map.get(refund_request, :internal_note, "")

    payload = %{
      amount: refund_amount,
      currency: charge.currency,
      reason: reason,
      is_partial: refund_amount < charge.amount,
      remaining_balance: charge.amount - refund_amount,
      operator_id: operator_id,
      internal_note: note,
      requested_at: DateTime.utc_now(),
      idempotency_key: generate_idempotency_key(charge.id, operator_id)
    }

    {:ok, payload}
  end

  defp assert_charge_capturable(%{status: :captured}), do: :ok
  defp assert_charge_capturable(%{status: status}), do: {:error, {:non_refundable_status, status}}

  defp validate_reason(reason) when reason in @refund_reasons, do: {:ok, reason}
  defp validate_reason(reason), do: {:error, {:invalid_reason, reason}}

  defp generate_idempotency_key(charge_id, operator_id) do
    :crypto.hash(:sha256, "#{charge_id}:#{operator_id}:#{System.system_time(:millisecond)}")
    |> Base.encode16(case: :lower)
  end
end
```
