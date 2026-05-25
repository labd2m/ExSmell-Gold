```elixir
defmodule RefundPolicy do
  @moduledoc """
  Enforces business rules around refund eligibility, approval
  workflows, and accounting ledger classification for a
  payment operations team.
  """

  alias RefundPolicy.{
    RefundRequest,
    Transaction,
    ApprovalWorkflow,
    LedgerEntry,
    AuditLog
  }

  @type refund_reason ::
          :duplicate_charge
          | :product_not_received
          | :product_defective
          | :customer_request
          | :fraud

  @max_auto_refund_amount 150.00

  @spec process_refund_request(RefundRequest.t()) ::
          {:ok, :auto_approved} | {:ok, :pending_approval} | {:error, String.t()}
  def process_refund_request(%RefundRequest{} = request) do
    with :ok <- validate_refund_window(request.transaction),
         :ok <- validate_amount(request) do
      if requires_approval?(request.reason) or request.amount > @max_auto_refund_amount do
        ApprovalWorkflow.submit(request)
        AuditLog.record(:refund_pending_approval, request.id, %{reason: request.reason})
        {:ok, :pending_approval}
      else
        execute_auto_refund(request)
      end
    end
  end

  @spec build_ledger_entry(RefundRequest.t(), float()) :: LedgerEntry.t()
  def build_ledger_entry(%RefundRequest{} = request, amount) do
    %LedgerEntry{
      reference: request.id,
      amount: -amount,
      code: ledger_code(request.reason),
      description: refund_description(request.reason),
      posted_at: DateTime.utc_now()
    }
  end

  @spec refund_report([RefundRequest.t()]) :: map()
  def refund_report(requests) do
    by_reason = Enum.group_by(requests, & &1.reason)

    Enum.into(by_reason, %{}, fn {reason, reqs} ->
      total = Enum.sum(Enum.map(reqs, & &1.amount))
      {reason, %{count: length(reqs), total: total, ledger_code: ledger_code(reason)}}
    end)
  end

  @spec requires_approval?(refund_reason()) :: boolean()
  def requires_approval?(reason) do
    case reason do
      :duplicate_charge     -> false
      :product_not_received -> false
      :product_defective    -> false
      :customer_request     -> true
      :fraud                -> true
    end
  end

  @spec ledger_code(refund_reason()) :: String.t()
  def ledger_code(reason) do
    case reason do
      :duplicate_charge     -> "RF-DUP"
      :product_not_received -> "RF-PNR"
      :product_defective    -> "RF-DEF"
      :customer_request     -> "RF-CRQ"
      :fraud                -> "RF-FRD"
    end
  end

  @spec refund_description(refund_reason()) :: String.t()
  defp refund_description(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @spec validate_refund_window(Transaction.t()) :: :ok | {:error, String.t()}
  defp validate_refund_window(%Transaction{captured_at: captured_at}) do
    days_since = Date.diff(Date.utc_today(), DateTime.to_date(captured_at))

    if days_since <= 180 do
      :ok
    else
      {:error, "refund window of 180 days has expired"}
    end
  end

  @spec validate_amount(RefundRequest.t()) :: :ok | {:error, String.t()}
  defp validate_amount(%RefundRequest{amount: amount, transaction: txn}) do
    if amount > 0 and amount <= txn.amount do
      :ok
    else
      {:error, "refund amount #{amount} is invalid for transaction of #{txn.amount}"}
    end
  end

  @spec execute_auto_refund(RefundRequest.t()) ::
          {:ok, :auto_approved} | {:error, String.t()}
  defp execute_auto_refund(%RefundRequest{} = request) do
    AuditLog.record(:refund_auto_approved, request.id, %{reason: request.reason})
    {:ok, :auto_approved}
  end
end
```
