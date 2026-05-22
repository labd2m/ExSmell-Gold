```elixir
defmodule MyApp.PaymentProcessor do
  @moduledoc """
  Integrates with the upstream payment gateway to handle one-time charges,
  refunds, and payment method management.
  """

  alias MyApp.{Repo, Order, Payment, PaymentMethod, Customer}
  alias MyApp.Gateway.Client, as: GatewayClient
  require Logger

  @supported_currencies ~w(USD EUR GBP BRL)
  @max_retry_attempts 3


  # charge/2
  #
  # Charges a customer for a given order using their stored payment method.
  #
  # Arguments:
  #   order_id    - integer, ID of the order to be charged
  #   options     - keyword list with optional overrides:
  #                   :currency     - 3-letter currency code (default: "USD")
  #                   :description  - string to appear on bank statement
  #                   :idempotency_key - string to prevent duplicate charges
  #
  # The function fetches the order, validates its status, retrieves the
  # customer's default payment method, and submits the charge to the gateway.
  # On gateway success it persists a Payment record and transitions the order
  # to :paid. Retries up to @max_retry_attempts times on transient errors.
  #
  # Returns {:ok, payment} or {:error, reason}.

  def charge(order_id, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")
    description = Keyword.get(opts, :description, "Order #{order_id}")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_idempotency_key(order_id))

    unless currency in @supported_currencies do
      raise ArgumentError, "Unsupported currency: #{currency}"
    end

    with {:ok, order} <- fetch_pending_order(order_id),
         {:ok, payment_method} <- fetch_default_payment_method(order.customer_id),
         {:ok, gateway_response} <-
           attempt_gateway_charge(
             payment_method,
             order.total_amount,
             currency,
             description,
             idempotency_key
           ) do
      {:ok, payment} = record_payment(order, gateway_response, currency)
      {:ok, _} = mark_order_paid(order)
      Logger.info("[Payment] Order #{order_id} charged successfully — txn #{gateway_response.transaction_id}")
      {:ok, payment}
    else
      {:error, :order_not_found} = err -> err
      {:error, :no_payment_method} = err -> err
      {:error, reason} ->
        Logger.error("[Payment] Charge failed for order #{order_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refunds a previously captured payment in full or partially.

  Submits the refund request to the gateway, updates the payment record's
  `refunded_amount`, and transitions the associated order to `:refunded` if the
  full amount has been returned.

  Returns `{:ok, payment}` or `{:error, reason}`.
  """
  def refund(payment_id, amount \\ :full) do
    with {:ok, payment} <- fetch_payment(payment_id),
         refund_amount <- resolve_refund_amount(payment, amount),
         {:ok, _response} <- GatewayClient.refund(payment.gateway_transaction_id, refund_amount) do
      new_refunded = (payment.refunded_amount || 0) + refund_amount

      payment
      |> Payment.changeset(%{refunded_amount: new_refunded})
      |> Repo.update()
    end
  end

  ## Private

  defp fetch_pending_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :order_not_found}
      %Order{status: :pending} = order -> {:ok, order}
      _ -> {:error, :invalid_order_status}
    end
  end

  defp fetch_default_payment_method(customer_id) do
    case Repo.get_by(PaymentMethod, customer_id: customer_id, default: true) do
      nil -> {:error, :no_payment_method}
      pm -> {:ok, pm}
    end
  end

  defp attempt_gateway_charge(payment_method, amount, currency, description, idempotency_key, attempt \\ 1) do
    case GatewayClient.charge(%{
           token: payment_method.gateway_token,
           amount: amount,
           currency: currency,
           description: description,
           idempotency_key: idempotency_key
         }) do
      {:ok, _} = success ->
        success

      {:error, :transient_error} when attempt < @max_retry_attempts ->
        Process.sleep(200 * attempt)
        attempt_gateway_charge(payment_method, amount, currency, description, idempotency_key, attempt + 1)

      {:error, _} = failure ->
        failure
    end
  end

  defp record_payment(order, gateway_response, currency) do
    %Payment{}
    |> Payment.changeset(%{
      order_id: order.id,
      customer_id: order.customer_id,
      amount: order.total_amount,
      currency: currency,
      gateway_transaction_id: gateway_response.transaction_id,
      status: :captured,
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp mark_order_paid(order) do
    order |> Order.changeset(%{status: :paid}) |> Repo.update()
  end

  defp fetch_payment(payment_id) do
    case Repo.get(Payment, payment_id) do
      nil -> {:error, :payment_not_found}
      payment -> {:ok, payment}
    end
  end

  defp resolve_refund_amount(_payment, :full), do: _payment.amount
  defp resolve_refund_amount(_payment, amount) when is_integer(amount), do: amount

  defp generate_idempotency_key(order_id) do
    :crypto.hash(:sha256, "order-#{order_id}-#{System.system_time(:millisecond)}")
    |> Base.encode16(case: :lower)
  end
end
```
