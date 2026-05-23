```elixir
defmodule Payments.ChargeProcessor do
  @moduledoc """
  Orchestrates payment charge operations and coordinates with the payment gateway.
  """

  alias Payments.{PaymentMethod, Charge, Gateway, Idempotency, FraudChecker}
  require Logger

  @max_single_charge_usd 50_000
  @high_fraud_threshold 70

  def process_charge(amount, currency, payment_method_id, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key, Idempotency.generate())

    with {:ok, method} <- PaymentMethod.fetch(payment_method_id),
         :ok <- validate_charge_amount(amount),
         {:ok, fraud_score} <- FraudChecker.evaluate(method.id, amount),
         :ok <- check_fraud_score(fraud_score),
         {:ok, charge} <- Gateway.charge(method, amount, currency, idempotency_key) do
      Charge.persist(charge)
    end
  end

  def refund_charge(charge_id, amount \\ nil) do
    with {:ok, charge} <- Charge.fetch(charge_id) do
      refund_amount = amount || charge.amount
      Gateway.refund(charge.gateway_charge_id, refund_amount)
    end
  end

  def void_charge(charge_id) do
    with {:ok, charge} <- Charge.fetch(charge_id),
         :ok <- validate_voidable(charge) do
      Gateway.void(charge.gateway_charge_id)
    end
  end

  def list_charges_for_method(payment_method_id) do
    Charge.list_by_method(payment_method_id)
  end

  def prepare_charge_details(payment_method_id) do
    method = PaymentMethod.fetch!(payment_method_id)

    type = PaymentMethod.type(method)
    billing_address = PaymentMethod.billing_address(method)
    expiry = PaymentMethod.expiry(method)
    is_verified = PaymentMethod.is_verified?(method)
    supported_currencies = PaymentMethod.supported_currencies(method)
    network = PaymentMethod.network(method)
    bank = PaymentMethod.issuing_bank(method)

    expiry_date =
      Date.from_iso8601!(
        "#{expiry.year}-#{String.pad_leading("#{expiry.month}", 2, "0")}-01"
      )

    days_until_expiry = Date.diff(expiry_date, Date.utc_today())
    is_expiring_soon = days_until_expiry < 60

    address_complete =
      not is_nil(billing_address.street) and
        not is_nil(billing_address.city) and
        not is_nil(billing_address.postal_code)

    %{
      method_id: method.id,
      type: type,
      last_four: method.last_four,
      holder_name: method.holder_name,
      network: network,
      issuing_bank: bank,
      country: method.country,
      fingerprint: method.fingerprint,
      is_verified: is_verified,
      billing_address: billing_address,
      billing_address_complete: address_complete,
      supported_currencies: supported_currencies,
      expiry_month: expiry.month,
      expiry_year: expiry.year,
      days_until_expiry: days_until_expiry,
      is_expiring_soon: is_expiring_soon
    }
  end

  defp validate_charge_amount(amount) when amount > 0 and amount <= @max_single_charge_usd,
    do: :ok

  defp validate_charge_amount(amount) when amount > @max_single_charge_usd,
    do: {:error, :amount_exceeds_limit}

  defp validate_charge_amount(_), do: {:error, :invalid_amount}

  defp check_fraud_score(score) when score < @high_fraud_threshold, do: :ok
  defp check_fraud_score(_score), do: {:error, :high_fraud_risk}

  defp validate_voidable(%Charge{status: :pending}), do: :ok
  defp validate_voidable(_), do: {:error, :not_voidable}
end
```
