```elixir
# ── file: lib/payments/processor.ex ──────────────────────────────────────────

defmodule Payments.Processor do
  @moduledoc """
  Handles charging customer payment methods via configured gateway adapters.
  Supports Stripe, Braintree, and Adyen through a unified interface.
  """

  alias Payments.{
    Gateway,
    PaymentMethod,
    Transaction,
    IdempotencyStore,
    Ledger
  }

  @max_retry_attempts 3
  @retry_backoff_ms 500

  @type charge_result ::
          {:ok, Transaction.t()}
          | {:error, :insufficient_funds}
          | {:error, :card_declined}
          | {:error, :gateway_timeout}
          | {:error, term()}

  @spec charge(PaymentMethod.t(), map()) :: charge_result()
  def charge(%PaymentMethod{} = method, attrs) do
    idempotency_key = Map.fetch!(attrs, :idempotency_key)

    case IdempotencyStore.get(idempotency_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        amount = Map.fetch!(attrs, :amount_cents)
        currency = Map.get(attrs, :currency, "usd")
        description = Map.get(attrs, :description, "")

        result = attempt_charge(method, amount, currency, description, 0)

        with {:ok, transaction} <- result do
          IdempotencyStore.put(idempotency_key, transaction)
          Ledger.record_credit(transaction)
        end

        result
    end
  end

  @spec authorize(PaymentMethod.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def authorize(%PaymentMethod{} = method, amount_cents, currency) do
    Gateway.authorize(method.gateway, %{
      token: method.token,
      amount: amount_cents,
      currency: currency
    })
  end

  @spec capture(String.t(), pos_integer()) :: {:ok, Transaction.t()} | {:error, term()}
  def capture(authorization_id, amount_cents) do
    with {:ok, raw} <- Gateway.capture(authorization_id, amount_cents) do
      transaction = Transaction.from_gateway_response(raw)
      Ledger.record_credit(transaction)
      {:ok, transaction}
    end
  end

  defp attempt_charge(_method, _amount, _currency, _desc, @max_retry_attempts) do
    {:error, :gateway_timeout}
  end

  defp attempt_charge(method, amount, currency, desc, attempt) do
    case Gateway.charge(method.gateway, %{
           token: method.token,
           amount: amount,
           currency: currency,
           description: desc
         }) do
      {:ok, raw} ->
        {:ok, Transaction.from_gateway_response(raw)}

      {:error, :retryable} ->
        Process.sleep(@retry_backoff_ms * (attempt + 1))
        attempt_charge(method, amount, currency, desc, attempt + 1)

      {:error, _} = err ->
        err
    end
  end
end


# ── file: lib/payments/refund_processor.ex ───────────────────────────────────

defmodule Payments.Processor do
  @moduledoc """
  Handles refund operations against previously captured transactions.
  Supports full and partial refunds with audit trail generation.
  """

  alias Payments.{Gateway, Transaction, Ledger, AuditLog}

  @type refund_result ::
          {:ok, Transaction.t()}
          | {:error, :already_refunded}
          | {:error, :amount_exceeds_original}
          | {:error, term()}

  @spec refund(Transaction.t(), map()) :: refund_result()
  def refund(%Transaction{status: :captured} = transaction, opts \\ %{}) do
    amount = Map.get(opts, :amount_cents, transaction.amount_cents)

    with :ok <- validate_refund_amount(transaction, amount),
         {:ok, raw} <-
           Gateway.refund(transaction.gateway, %{
             original_id: transaction.gateway_id,
             amount: amount,
             reason: Map.get(opts, :reason, "requested_by_customer")
           }) do
      refund_tx = Transaction.from_gateway_response(raw, type: :refund)
      Ledger.record_debit(refund_tx)

      AuditLog.write(:refund_processed, %{
        original_transaction_id: transaction.id,
        refund_transaction_id: refund_tx.id,
        amount: amount
      })

      {:ok, refund_tx}
    end
  end

  def refund(%Transaction{status: :refunded}, _), do: {:error, :already_refunded}
  def refund(%Transaction{}, _), do: {:error, :transaction_not_capturable}

  @spec void(Transaction.t()) :: {:ok, Transaction.t()} | {:error, term()}
  def void(%Transaction{status: :authorized} = transaction) do
    with {:ok, _} <- Gateway.void(transaction.gateway, transaction.gateway_id) do
      voided = %{transaction | status: :voided}
      AuditLog.write(:transaction_voided, %{transaction_id: transaction.id})
      {:ok, voided}
    end
  end

  def void(_), do: {:error, :cannot_void_non_authorized_transaction}

  defp validate_refund_amount(%Transaction{amount_cents: original}, requested)
       when requested <= original and requested > 0,
       do: :ok

  defp validate_refund_amount(_, _), do: {:error, :amount_exceeds_original}
end
```
