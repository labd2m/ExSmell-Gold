```elixir
defmodule RefundEngine do
  @moduledoc """
  Orchestrates the refund lifecycle: eligibility checks, approval workflows,
  accounting reversal code assignment, and customer communication
  for the payments platform.
  """

  require Logger

  @refund_reasons [:duplicate_charge, :product_not_received, :fraudulent, :customer_request]

  def valid_reasons, do: @refund_reasons







  @doc """
  Returns true when the refund reason requires explicit manager sign-off before
  the refund can be processed.
  """
  def requires_manager_approval?(%{reason: reason}) do
    case reason do
      :duplicate_charge -> false
      :product_not_received -> false
      :fraudulent -> true
      :customer_request -> false
      _ -> true
    end
  end

  @doc """
  Returns the customer-facing email copy body for the refund confirmation,
  tailored to the reason for the refund.
  """
  def customer_notification_copy(%{reason: reason, amount: amount}) do
    amount_str = "$#{:erlang.float_to_binary(amount / 100.0, decimals: 2)}"

    case reason do
      :duplicate_charge ->
        "We identified a duplicate charge on your account and have issued a refund of #{amount_str}."

      :product_not_received ->
        "As your order was not delivered, we have processed a full refund of #{amount_str}."

      :fraudulent ->
        "We detected unauthorized activity on your account and have reversed the charge of #{amount_str}."

      :customer_request ->
        "Your refund of #{amount_str} has been processed as requested."

      _ ->
        "A refund of #{amount_str} has been issued to your original payment method."
    end
  end

  @doc """
  Returns the accounting reversal code used when posting the refund to the
  general ledger.
  """
  def accounting_reversal_code(%{reason: reason}) do
    case reason do
      :duplicate_charge -> "REV-DUPE"
      :product_not_received -> "REV-NONDELV"
      :fraudulent -> "REV-FRAUD"
      :customer_request -> "REV-CUST"
      _ -> "REV-MISC"
    end
  end



  @doc """
  Validates that a refund request struct is well-formed and eligible for processing.
  """
  def validate_request(%{reason: reason, amount: amount, transaction_id: _tx_id} = refund)
      when reason in @refund_reasons and is_number(amount) and amount > 0 do
    {:ok, refund}
  end

  def validate_request(%{reason: reason}) when reason not in @refund_reasons do
    {:error, {:unknown_reason, reason}}
  end

  def validate_request(_), do: {:error, :invalid_refund_request}

  @doc """
  Initiates a refund by going through the full workflow: validate, check approval,
  compute code, post to ledger, and send customer notification.
  """
  def initiate(%{} = refund_request, requester) do
    with {:ok, valid_refund} <- validate_request(refund_request) do
      needs_approval = requires_manager_approval?(valid_refund)

      if needs_approval and not Map.get(requester, :is_manager, false) do
        Logger.warning(
          "Refund #{valid_refund.reason} requires manager approval; escalating."
        )
        {:pending, :awaiting_manager_approval}
      else
        code = accounting_reversal_code(valid_refund)
        copy = customer_notification_copy(valid_refund)

        Logger.info(
          "Processing refund [#{code}] for transaction #{valid_refund.transaction_id}."
        )

        notify_customer(valid_refund, copy)
        post_to_ledger(valid_refund, code)

        {:ok,
         %{
           status: :processed,
           reversal_code: code,
           transaction_id: valid_refund.transaction_id,
           processed_at: DateTime.utc_now()
         }}
      end
    end
  end

  @doc """
  Approves a pending refund that required manager sign-off.
  """
  def approve_pending(%{} = refund_request, approving_manager) do
    if Map.get(approving_manager, :is_manager, false) do
      initiate(refund_request, approving_manager)
    else
      {:error, :insufficient_permissions}
    end
  end



  defp notify_customer(%{transaction_id: tx_id}, copy) do
    Logger.debug("Notifying customer for transaction #{tx_id}: #{copy}")
  end

  defp post_to_ledger(%{transaction_id: tx_id}, code) do
    Logger.debug("Posting ledger reversal #{code} for transaction #{tx_id}.")
  end
end
```
