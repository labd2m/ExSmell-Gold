```elixir
defmodule Payments.GatewayAdapter do
  @moduledoc """
  Wraps third-party payment gateway SDKs to provide a uniform interface
  for charging, refunding, and verifying webhook signatures.
  """


  @spec charge(atom(), map(), map()) :: {:ok, map()} | {:error, term()}
  def charge(:stripe, customer, order) do
    Stripe.Charge.create(%{
      amount:   round(order.total_cents),
      currency: order.currency,
      customer: customer.stripe_id,
      metadata: %{order_id: order.id}
    })
    |> case do
      {:ok, charge}  -> {:ok, %{transaction_id: charge.id, status: :captured}}
      {:error, err}  -> {:error, err}
    end
  end

  def charge(:paypal, customer, order) do
    PayPal.Orders.capture(%{
      amount:         %{value: to_string(order.total / 100), currency_code: order.currency},
      reference_id:   order.id,
      payer:          %{payer_id: customer.paypal_id}
    })
    |> case do
      {:ok, result}  -> {:ok, %{transaction_id: result["id"], status: :captured}}
      {:error, err}  -> {:error, err}
    end
  end

  def charge(:braintree, customer, order) do
    Braintree.Transaction.sale(%{
      amount:                  :erlang.float_to_binary(order.total / 100, decimals: 2),
      payment_method_nonce:    customer.braintree_nonce,
      options:                 %{submit_for_settlement: true}
    })
    |> case do
      {:ok, txn}    -> {:ok, %{transaction_id: txn.id, status: :captured}}
      {:error, err} -> {:error, err}
    end
  end

  @spec refund(atom(), map()) :: {:ok, map()} | {:error, term()}
  def refund(:stripe, %{transaction_id: txn_id, amount_cents: amount}) do
    Stripe.Refund.create(%{charge: txn_id, amount: amount})
    |> case do
      {:ok, r}       -> {:ok, %{refund_id: r.id}}
      {:error, err}  -> {:error, err}
    end
  end

  def refund(:paypal, %{transaction_id: txn_id, amount_cents: amount}) do
    PayPal.Payments.refund(txn_id, %{amount: %{value: to_string(amount / 100)}})
    |> case do
      {:ok, r}       -> {:ok, %{refund_id: r["id"]}}
      {:error, err}  -> {:error, err}
    end
  end

  def refund(:braintree, %{transaction_id: txn_id}) do
    Braintree.Transaction.refund(txn_id)
    |> case do
      {:ok, r}       -> {:ok, %{refund_id: r.id}}
      {:error, err}  -> {:error, err}
    end
  end

  @spec webhook_secret(atom()) :: String.t()
  def webhook_secret(:stripe),     do: System.get_env("STRIPE_WEBHOOK_SECRET")
  def webhook_secret(:paypal),     do: System.get_env("PAYPAL_WEBHOOK_ID")
  def webhook_secret(:braintree),  do: System.get_env("BRAINTREE_WEBHOOK_SECRET")

end

defmodule Payments.FeePolicy do
  @moduledoc """
  Defines platform-level processing fee rates and refund capabilities
  for each integrated payment gateway.
  """


  @spec fee_percentage(atom()) :: float()
  def fee_percentage(:stripe),    do: 2.9
  def fee_percentage(:paypal),    do: 3.49
  def fee_percentage(:braintree), do: 2.59

  @spec supports_partial_refund?(atom()) :: boolean()
  def supports_partial_refund?(:stripe),    do: true
  def supports_partial_refund?(:paypal),    do: true
  def supports_partial_refund?(:braintree), do: true


  def net_revenue(gateway, gross_cents) do
    rate = fee_percentage(gateway) / 100
    fixed_fee_cents = 30
    round(gross_cents - gross_cents * rate - fixed_fee_cents)
  end
end

defmodule Payments.ReceiptBuilder do
  @moduledoc """
  Builds customer-facing payment receipts, including gateway branding
  and transaction references formatted per provider conventions.
  """


  @spec provider_label(atom()) :: String.t()
  def provider_label(:stripe),    do: "Stripe"
  def provider_label(:paypal),    do: "PayPal"
  def provider_label(:braintree), do: "Braintree (PayPal)"


  def build(order, payment) do
    %{
      receipt_number:  "REC-#{order.id}",
      customer_name:   order.customer.full_name,
      amount:          format_currency(payment.amount_cents, order.currency),
      payment_method:  provider_label(payment.gateway),
      transaction_ref: payment.transaction_id,
      issued_at:       DateTime.utc_now()
    }
  end

  defp format_currency(cents, currency) do
    "#{:erlang.float_to_binary(cents / 100, decimals: 2)} #{String.upcase(currency)}"
  end
end
```
