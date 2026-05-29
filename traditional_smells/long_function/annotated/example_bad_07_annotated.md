# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Payments.Processor.charge/3`
- **Affected function(s):** `charge/3`
- **Short explanation:** The `charge/3` function performs idempotency key checking, payment method validation, fraud scoring, gateway charge dispatch, transaction recording, order status update, and receipt email triggering all in a single body. Each of these is a discrete step with its own logic, and the function grows well beyond what any single function should do.

---

```elixir
defmodule Payments.Processor do
  @moduledoc """
  Processes payment charges for orders, handling idempotency, fraud checks,
  and gateway communication.
  """

  alias Payments.{Transaction, PaymentMethod, IdempotencyKey, Repo}
  alias Orders.Order
  alias Integrations.{StripeGateway, FraudScorer, Mailer}
  require Logger

  @fraud_score_threshold 0.75
  @max_charge_amount_cents 500_000

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `charge/3` conflates idempotency checking,
  # VALIDATION: payment method retrieval, amount validation, fraud scoring,
  # VALIDATION: gateway invocation, transaction persistence, order update,
  # VALIDATION: and receipt delivery all inside one function with no extraction.
  def charge(%Order{} = order, payment_method_id, idempotency_key) do
    Logger.info("Charging order=#{order.id} pm=#{payment_method_id} key=#{idempotency_key}")

    # --- Idempotency check ---
    case Repo.get_by(IdempotencyKey, key: idempotency_key) do
      %IdempotencyKey{transaction_id: txn_id} ->
        Logger.info("Duplicate charge request, returning existing transaction #{txn_id}")
        {:ok, Repo.get!(Transaction, txn_id)}

      nil ->
        # --- Load and validate payment method ---
        case Repo.get_by(PaymentMethod, id: payment_method_id, user_id: order.user_id) do
          nil ->
            {:error, :payment_method_not_found}

          %PaymentMethod{status: :expired} ->
            {:error, :payment_method_expired}

          %PaymentMethod{} = pm ->
            amount_cents = round(order.total * 100)

            if amount_cents <= 0 or amount_cents > @max_charge_amount_cents do
              {:error, {:invalid_amount, amount_cents}}
            else
              # --- Fraud score ---
              fraud_input = %{
                user_id: order.user_id,
                amount_cents: amount_cents,
                ip_address: order.metadata[:ip_address],
                country: order.shipping_address.country
              }

              fraud_score =
                case FraudScorer.score(fraud_input) do
                  {:ok, %{score: s}} -> s
                  _                  -> 0.0
                end

              if fraud_score >= @fraud_score_threshold do
                Logger.warning("Fraud risk #{fraud_score} for order #{order.id}, blocking charge")
                {:error, {:fraud_risk, fraud_score}}
              else
                # --- Charge via gateway ---
                gateway_payload = %{
                  amount: amount_cents,
                  currency: order.currency || "usd",
                  payment_method: pm.gateway_token,
                  description: "Order #{order.id}",
                  idempotency_key: idempotency_key,
                  metadata: %{order_id: order.id, user_id: order.user_id}
                }

                case StripeGateway.charge(gateway_payload) do
                  {:ok, %{charge_id: charge_id, status: gw_status}} ->
                    # --- Record transaction ---
                    txn_attrs = %{
                      order_id: order.id,
                      user_id: order.user_id,
                      payment_method_id: pm.id,
                      gateway: :stripe,
                      gateway_charge_id: charge_id,
                      amount_cents: amount_cents,
                      currency: order.currency || "usd",
                      status: if(gw_status == "succeeded", do: :captured, else: :pending),
                      fraud_score: fraud_score,
                      charged_at: DateTime.utc_now()
                    }

                    {:ok, txn} = Repo.insert(Transaction.changeset(%Transaction{}, txn_attrs))

                    # --- Register idempotency key ---
                    Repo.insert!(%IdempotencyKey{key: idempotency_key, transaction_id: txn.id})

                    # --- Update order status ---
                    order
                    |> Order.changeset(%{
                      status: :paid,
                      paid_at: DateTime.utc_now(),
                      transaction_id: txn.id
                    })
                    |> Repo.update!()

                    # --- Send receipt ---
                    Mailer.send_receipt(%{
                      to: order.customer_email,
                      order_id: order.id,
                      amount: order.total,
                      currency: order.currency || "USD",
                      transaction_id: txn.id
                    })

                    Logger.info("Charge succeeded for order #{order.id}, txn=#{txn.id}")
                    {:ok, txn}

                  {:error, %{code: code, message: msg}} ->
                    Logger.error("Gateway charge failed for order #{order.id}: #{code} - #{msg}")
                    {:error, {:gateway_error, code, msg}}
                end
              end
            end
        end
    end
  end
  # VALIDATION: SMELL END

  def refund(transaction_id, reason \\ :requested_by_customer) do
    case Repo.get(Transaction, transaction_id) do
      nil -> {:error, :transaction_not_found}
      txn -> StripeGateway.refund(txn.gateway_charge_id, reason)
    end
  end
end
```
