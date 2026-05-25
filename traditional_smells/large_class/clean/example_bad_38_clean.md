```elixir
defmodule PaymentProcessor do
  @moduledoc """
  Handles all payment operations: authorization, capture, refunds,
  customer vault management, transaction history, receipt generation,
  and gateway webhook processing.
  """

  require Logger
  alias Payments.Repo
  alias Payments.Transaction
  alias Payments.CustomerProfile
  alias Payments.PaymentMethod
  alias Payments.WebhookEvent

  @gateway_timeout_ms 10_000


  def charge(customer_id, amount_cents, opts \\ []) do
    profile = Repo.get!(CustomerProfile, customer_id)
    default_pm = get_default_payment_method(profile.id)
    idempotency_key = Keyword.get(opts, :idempotency_key, UUID.uuid4())

    gateway_params = %{
      amount: amount_cents,
      currency: Keyword.get(opts, :currency, "USD"),
      payment_method_token: default_pm.gateway_token,
      idempotency_key: idempotency_key,
      description: Keyword.get(opts, :description, "")
    }

    case GatewayClient.charge(gateway_params, timeout: @gateway_timeout_ms) do
      {:ok, %{transaction_id: txn_id, status: "settled"}} ->
        {:ok, record_transaction(customer_id, :charge, amount_cents, txn_id, :settled)}

      {:ok, %{transaction_id: txn_id, status: status}} ->
        {:ok, record_transaction(customer_id, :charge, amount_cents, txn_id, status)}

      {:error, %{code: code, message: msg}} ->
        Logger.error("Charge failed for customer #{customer_id}: #{code} — #{msg}")
        {:error, %{code: code, message: msg}}
    end
  end

  defp record_transaction(customer_id, type, amount_cents, gateway_txn_id, status) do
    Repo.insert!(
      Transaction.changeset(%Transaction{}, %{
        customer_id: customer_id,
        type: type,
        amount_cents: amount_cents,
        gateway_transaction_id: gateway_txn_id,
        status: status,
        occurred_at: DateTime.utc_now()
      })
    )
  end

  defp get_default_payment_method(customer_id) do
    PaymentMethod
    |> PaymentMethod.for_customer(customer_id)
    |> PaymentMethod.default()
    |> Repo.one!()
  end


  def authorize(customer_id, amount_cents, opts \\ []) do
    profile = Repo.get!(CustomerProfile, customer_id)
    pm = get_default_payment_method(profile.id)

    case GatewayClient.authorize(%{amount: amount_cents, payment_method_token: pm.gateway_token},
           timeout: @gateway_timeout_ms
         ) do
      {:ok, %{authorization_code: auth_code, transaction_id: txn_id}} ->
        txn = record_transaction(customer_id, :authorization, amount_cents, txn_id, :authorized)
        {:ok, Map.put(txn, :authorization_code, auth_code)}

      {:error, _} = err ->
        err
    end
  end


  def capture(authorization_code, amount_cents) do
    case GatewayClient.capture(%{authorization_code: authorization_code, amount: amount_cents},
           timeout: @gateway_timeout_ms
         ) do
      {:ok, %{transaction_id: txn_id}} ->
        Logger.info("Captured #{amount_cents} cents under auth #{authorization_code}")
        {:ok, txn_id}

      {:error, _} = err ->
        err
    end
  end


  def void_authorization(authorization_code, reason) do
    case GatewayClient.void(%{authorization_code: authorization_code}) do
      {:ok, _} ->
        Logger.info("Authorization #{authorization_code} voided: #{reason}")
        :ok

      {:error, _} = err ->
        err
    end
  end


  def refund(transaction_id, amount_cents, reason) do
    txn = Repo.get!(Transaction, transaction_id)

    case GatewayClient.refund(%{
           original_transaction_id: txn.gateway_transaction_id,
           amount: amount_cents
         },
           timeout: @gateway_timeout_ms
         ) do
      {:ok, %{transaction_id: refund_txn_id}} ->
        Repo.update!(Transaction.changeset(txn, %{status: :refunded}))
        refund_record = record_transaction(txn.customer_id, :refund, amount_cents, refund_txn_id, :settled)
        Logger.info("Refunded #{amount_cents} cents for txn #{transaction_id}: #{reason}")
        {:ok, refund_record}

      {:error, _} = err ->
        err
    end
  end


  def create_customer_profile(user) do
    case GatewayClient.create_customer(%{email: user.email, external_id: user.id}) do
      {:ok, %{customer_id: gw_customer_id}} ->
        Repo.insert(
          CustomerProfile.changeset(%CustomerProfile{}, %{
            user_id: user.id,
            gateway_customer_id: gw_customer_id
          })
        )

      {:error, _} = err ->
        err
    end
  end

  def update_payment_method(customer_id, card_token) do
    profile = Repo.get!(CustomerProfile, customer_id)

    case GatewayClient.add_payment_method(%{
           gateway_customer_id: profile.gateway_customer_id,
           token: card_token
         }) do
      {:ok, %{payment_method_token: pm_token}} ->
        Repo.insert(
          PaymentMethod.changeset(%PaymentMethod{}, %{
            customer_id: customer_id,
            gateway_token: pm_token,
            is_default: true
          })
        )

      {:error, _} = err ->
        err
    end
  end


  def list_transactions(customer_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    Transaction
    |> Transaction.for_customer(customer_id)
    |> Transaction.order_by_newest()
    |> Repo.paginate(page: page, page_size: per_page)
  end


  def generate_receipt(%Transaction{} = txn) do
    %{
      receipt_id: "RCP-#{txn.id}",
      transaction_id: txn.id,
      amount_cents: txn.amount_cents,
      amount_display: "$#{Float.round(txn.amount_cents / 100.0, 2)}",
      status: txn.status,
      occurred_at: txn.occurred_at,
      generated_at: DateTime.utc_now()
    }
  end


  def handle_webhook(%{"event_type" => event_type, "transaction_id" => gw_txn_id} = payload) do
    WebhookEvent
    |> WebhookEvent.changeset(%{event_type: event_type, raw_payload: payload, received_at: DateTime.utc_now()})
    |> Repo.insert()

    case event_type do
      "payment.settled" ->
        update_transaction_by_gateway_id(gw_txn_id, %{status: :settled})

      "payment.failed" ->
        update_transaction_by_gateway_id(gw_txn_id, %{status: :failed})

      "refund.completed" ->
        update_transaction_by_gateway_id(gw_txn_id, %{status: :refunded})

      _ ->
        Logger.debug("Unhandled webhook event type: #{event_type}")
    end

    :ok
  end

  defp update_transaction_by_gateway_id(gw_txn_id, changes) do
    case Repo.get_by(Transaction, gateway_transaction_id: gw_txn_id) do
      nil -> Logger.warning("Webhook received for unknown transaction #{gw_txn_id}")
      txn -> Repo.update!(Transaction.changeset(txn, changes))
    end
  end
end
```
