```elixir
defmodule MyApp.PaymentProcessor do
  @moduledoc """
  Wraps external payment gateway communication and persists payment
  records for the MyApp billing subsystem.
  """

  alias MyApp.Repo
  alias MyApp.Billing.{Payment, PaymentMethod, Refund}
  alias MyApp.Gateways.StripeClient

  require Logger

  @idempotency_key_prefix "myapp_charge_"

  @doc """
  Returns the active payment method for a given customer ID, or `nil` if none exists.
  """
  def active_payment_method(customer_id) do
    Repo.get_by(PaymentMethod, customer_id: customer_id, active: true)
  end


  # charge/2
  #
  # Initiates a payment charge for the given amount against the customer's
  # active payment method.
  #
  # Parameters:
  #   customer_id  — integer ID of the customer being charged
  #   amount_cents — positive integer, amount in the smallest currency unit (e.g. cents)
  #
  # Behaviour:
  #   1. Fetches the customer's active PaymentMethod.
  #   2. Builds an idempotency key from customer_id + current UTC timestamp (minute).
  #   3. Calls the Stripe gateway with the payment method token and amount.
  #   4. Persists a Payment record regardless of gateway outcome.
  #   5. On gateway decline, the payment record is marked as :failed.
  #
  # Returns:
  #   {:ok, %Payment{status: :succeeded}}  — charge accepted by gateway
  #   {:ok, %Payment{status: :failed}}     — charge declined by gateway
  #   {:error, :no_payment_method}         — no active payment method on file
  #   {:error, :gateway_error, message}    — unexpected gateway communication failure
  def charge(customer_id, amount_cents) do
    case active_payment_method(customer_id) do
      nil ->
        {:error, :no_payment_method}

      payment_method ->
        idempotency_key = build_idempotency_key(customer_id)
        attempt_charge(payment_method, amount_cents, idempotency_key)
    end
  end

  @doc """
  Issues a full or partial refund for a previously successful payment.

  Returns `{:ok, %Refund{}}` or `{:error, reason}`.
  """
  def refund(payment_id, amount_cents \\ nil) do
    case Repo.get(Payment, payment_id) do
      nil ->
        {:error, :payment_not_found}

      %Payment{status: :succeeded} = payment ->
        refund_amount = amount_cents || payment.amount_cents
        process_refund(payment, refund_amount)

      %Payment{status: status} ->
        {:error, {:not_refundable, status}}
    end
  end

  @doc """
  Returns a list of all payments for a customer, ordered by most recent first.
  """
  def payment_history(customer_id, limit \\ 20) do
    Payment
    |> Payment.for_customer(customer_id)
    |> Payment.ordered_desc()
    |> Payment.limit(limit)
    |> Repo.all()
  end

  # --- Private helpers ---

  defp attempt_charge(payment_method, amount_cents, idempotency_key) do
    gateway_params = %{
      payment_method_token: payment_method.gateway_token,
      amount: amount_cents,
      currency: "usd",
      idempotency_key: idempotency_key
    }

    case StripeClient.charge(gateway_params) do
      {:ok, gateway_response} ->
        payment = persist_payment(payment_method, amount_cents, :succeeded, gateway_response)
        {:ok, payment}

      {:declined, gateway_response} ->
        Logger.info("Charge declined for customer #{payment_method.customer_id}: #{inspect(gateway_response)}")
        payment = persist_payment(payment_method, amount_cents, :failed, gateway_response)
        {:ok, payment}

      {:error, message} ->
        Logger.error("Gateway error for customer #{payment_method.customer_id}: #{message}")
        {:error, :gateway_error, message}
    end
  end

  defp persist_payment(payment_method, amount_cents, status, gateway_response) do
    %Payment{}
    |> Payment.changeset(%{
      customer_id: payment_method.customer_id,
      payment_method_id: payment_method.id,
      amount_cents: amount_cents,
      status: status,
      gateway_reference: gateway_response[:id],
      processed_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp process_refund(payment, amount_cents) do
    case StripeClient.refund(payment.gateway_reference, amount_cents) do
      {:ok, gateway_response} ->
        %Refund{}
        |> Refund.changeset(%{
          payment_id: payment.id,
          amount_cents: amount_cents,
          gateway_reference: gateway_response[:id],
          refunded_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:error, message} ->
        {:error, {:gateway_refund_failed, message}}
    end
  end

  defp build_idempotency_key(customer_id) do
    minute = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix()
    "#{@idempotency_key_prefix}#{customer_id}_#{minute}"
  end
end
```
