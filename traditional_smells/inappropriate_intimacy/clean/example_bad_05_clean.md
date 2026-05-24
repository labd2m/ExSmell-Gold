```elixir
defmodule Payments.RefundProcessor do
  @moduledoc """
  Processes full and partial refunds against captured payment transactions.
  Validates refund eligibility and delegates the reversal to the appropriate payment gateway.
  """

  alias Payments.{Refund, RefundLedger, Repo}
  alias Transactions.Transaction
  alias Gateways.PaymentGateway

  require Logger

  @max_refund_window_days 180
  @refund_id_prefix "REF"

  @spec process(String.t(), Decimal.t(), String.t()) ::
          {:ok, Refund.t()} | {:error, atom()}
  def process(transaction_id, amount, reason) when is_binary(reason) do
    with {:ok, transaction} <- Transaction.fetch(transaction_id),
         :ok                <- ensure_captured(transaction),
         :ok                <- ensure_within_refund_window(transaction),
         :ok                <- validate_refund_amount(transaction, amount) do

      source = Transaction.fetch_payment_source(transaction)
      creds  = PaymentGateway.credentials_for(source.gateway_name)

      gateway_response =
        HTTPoisonAdapter.post(
          creds.endpoint_url <> "/refunds",
          %{
            api_key:        creds.api_key,
            api_secret:     creds.api_secret,
            transaction_id: source.gateway_transaction_id,
            amount:         Decimal.to_string(amount),
            currency:       transaction.currency
          }
        )

      case gateway_response do
        {:ok, %{status_code: 200, body: body}} ->
          refund = persist_refund(%{
            transaction_id:         transaction_id,
            gateway_name:           source.gateway_name,
            gateway_refund_id:      body["refund_id"],
            original_captured:      source.captured_amount,
            refund_amount:          amount,
            reason:                 reason,
            status:                 :succeeded
          })

          Logger.info("[RefundProcessor] Refund #{refund.id} succeeded via #{source.gateway_name}")
          {:ok, refund}

        {:ok, %{status_code: status, body: body}} ->
          Logger.error("[RefundProcessor] Gateway rejected refund: status=#{status} body=#{inspect(body)}")
          {:error, :gateway_rejected}

        {:error, reason} ->
          Logger.error("[RefundProcessor] Gateway unreachable: #{inspect(reason)}")
          {:error, :gateway_unreachable}
      end
    end
  end

  @spec list_for_transaction(String.t()) :: [Refund.t()]
  def list_for_transaction(transaction_id) do
    Repo.list_refunds_by_transaction(transaction_id)
  end

  @spec total_refunded(String.t()) :: Decimal.t()
  def total_refunded(transaction_id) do
    transaction_id
    |> list_for_transaction()
    |> Enum.filter(&(&1.status == :succeeded))
    |> Enum.reduce(Decimal.new(0), fn r, acc -> Decimal.add(acc, r.refund_amount) end)
  end


  defp ensure_captured(%{status: :captured}), do: :ok
  defp ensure_captured(%{status: :refunded}), do: {:error, :already_fully_refunded}
  defp ensure_captured(_), do: {:error, :transaction_not_refundable}

  defp ensure_within_refund_window(%{captured_at: captured_at}) do
    days_elapsed = Date.diff(Date.utc_today(), DateTime.to_date(captured_at))

    if days_elapsed <= @max_refund_window_days,
      do: :ok,
      else: {:error, :refund_window_expired}
  end

  defp validate_refund_amount(%{amount: captured} = txn, refund_amount) do
    already_refunded = total_refunded(txn.id)
    remaining        = Decimal.sub(captured, already_refunded)

    if Decimal.compare(refund_amount, remaining) != :gt,
      do: :ok,
      else: {:error, :refund_exceeds_available_balance}
  end

  defp persist_refund(attrs) do
    refund =
      %Refund{
        id:          "#{@refund_id_prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16()}",
        processed_at: DateTime.utc_now()
      }
      |> Map.merge(attrs)

    {:ok, saved} = Repo.insert(refund)
    :ok          = RefundLedger.record(saved)
    saved
  end
end
```
