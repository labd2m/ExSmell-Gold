# Code Smell: Working with invalid data

- **Smell name:** Working with invalid data
- **Expected smell location:** `process_refund/2`, where `refund_amount` is extracted from an external request map and forwarded to `PaymentGateway.refund/3` without type or range validation
- **Affected function(s):** `process_refund/2`, `build_refund_payload/3`
- **Short explanation:** `refund_amount` is read from a caller-supplied map using `Map.get/3` with no check confirming it is a positive number or within the original charge amount. The raw value flows into `build_refund_payload/3` where it participates in arithmetic (`original_amount - refund_amount`) and is then forwarded to `PaymentGateway.refund/3`. If a string, nil, or negative value is provided, the error will surface deep inside the payment gateway client, with no message pointing back to the unvalidated field at the refund boundary.

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

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `refund_amount` is taken directly
  # from the external `refund_request` map without any validation of its
  # type or value. The raw value is embedded in the payload and used in
  # the arithmetic expression `charge.amount - refund_amount` to compute
  # `remaining_balance`. It is also forwarded to `PaymentGateway.refund/3`.
  # If the caller passes a binary like "50.00", nil, or a negative number,
  # the crash will emerge inside the gateway client or in the arithmetic
  # operation with no reference to the refund boundary where the bad value
  # entered the system.
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
  # VALIDATION: SMELL END

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
