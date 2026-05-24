```elixir
defmodule MyApp.Payments.RefundProcessor do
  @moduledoc """
  Handles full and partial refunds for completed payment transactions.
  Enforces merchant-specific refund policies before initiating gateway calls.
  """

  alias MyApp.Payments.{Transaction, Gateway, RefundRecord}
  alias MyApp.Merchants.Merchant
  alias MyApp.Notifications.RefundMailer

  @max_refund_days 90

  def process(transaction_id, amount) do
    with {:ok, transaction} <- Transaction.fetch(transaction_id),
         {:ok, merchant}    <- Merchant.find(transaction.merchant_id) do

      gateway_ref    = transaction.gateway_reference
      captured_at    = transaction.captured_at
      settled        = transaction.settled

      policy         = merchant.refund_policy
      gateway_id     = merchant.gateway_id

      days_since = DateTime.diff(DateTime.utc_now(), captured_at, :day)

      cond do
        not settled ->
          {:error, :transaction_not_settled}

        days_since > @max_refund_days ->
          {:error, :refund_window_expired}

        policy == :no_refund ->
          {:error, :merchant_refund_policy_disallows}

        policy == :store_credit_only ->
          issue_store_credit(transaction, merchant, amount)

        amount > transaction.amount ->
          {:error, :refund_exceeds_original}

        true ->
          initiate_gateway_refund(gateway_id, gateway_ref, amount, transaction, merchant)
      end
    end
  end

  def list_for_merchant(merchant_id, opts \\ []) do
    limit  = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    :ets.tab2list(:refund_records)
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(fn r -> r.merchant_id == merchant_id end)
    |> then(fn records ->
      if status, do: Enum.filter(records, &(&1.status == status)), else: records
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def cancel_pending(refund_id) do
    case RefundRecord.fetch(refund_id) do
      nil                        -> {:error, :not_found}
      %{status: :completed}      -> {:error, :already_completed}
      %{status: :cancelled}      -> {:error, :already_cancelled}
      record                     -> RefundRecord.update(record, %{status: :cancelled})
    end
  end


  defp initiate_gateway_refund(gateway_id, gateway_ref, amount, transaction, merchant) do
    case Gateway.refund(gateway_id, gateway_ref, amount) do
      {:ok, gateway_response} ->
        record = build_record(transaction, merchant, amount, :completed, gateway_response.id)
        RefundRecord.save(record)
        RefundMailer.deliver_confirmation(transaction.customer_id, record)
        {:ok, record}

      {:error, reason} ->
        record = build_record(transaction, merchant, amount, :failed, nil)
        RefundRecord.save(record)
        {:error, reason}
    end
  end

  defp issue_store_credit(transaction, merchant, amount) do
    credit = %{
      account_id:  transaction.customer_id,
      merchant_id: merchant.id,
      amount:      amount,
      issued_at:   DateTime.utc_now(),
      expires_at:  DateTime.utc_now() |> DateTime.add(365 * 86_400, :second)
    }
    :ets.insert(:store_credits, {credit.account_id, credit})
    {:ok, %{type: :store_credit, credit: credit}}
  end

  defp build_record(transaction, merchant, amount, status, gateway_refund_id) do
    %{
      id:                generate_id(),
      transaction_id:    transaction.id,
      merchant_id:       merchant.id,
      amount:            amount,
      status:            status,
      gateway_refund_id: gateway_refund_id,
      created_at:        DateTime.utc_now()
    }
  end

  defp generate_id do
    "REF-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
