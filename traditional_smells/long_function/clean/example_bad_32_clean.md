```elixir
defmodule Payments.GatewayService do
  @moduledoc """
  Processes card charges through multiple payment gateways
  with built-in fraud screening and retry logic.
  """

  require Logger

  alias Payments.{
    PaymentIntent, Card, FraudScore, Gateway,
    ChargeRecord, Receipt, WebhookDispatcher
  }

  @max_retries         2
  @idempotency_ttl_sec 86_400
  @fraud_block_score   0.80

  def charge(%PaymentIntent{} = intent, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key)
    capture_method  = Keyword.get(opts, :capture_method, :immediate)

    # 1. Resolve idempotency — return cached result if key already used
    if idempotency_key do
      case ChargeRecord.find_by_idempotency_key(idempotency_key) do
        nil -> :proceed
        existing ->
          Logger.info("Idempotency hit for key #{idempotency_key}")
          {:ok, existing}
      end
    end

    # 2. Validate the payment intent
    cond do
      intent.amount_cents <= 0 ->
        {:error, :invalid_amount}

      intent.currency not in ~w(usd eur gbp brl) ->
        {:error, :unsupported_currency}

      true ->
        # 3. Validate card data
        case Card.validate(intent.card) do
          {:error, reason} ->
            {:error, {:card_validation_failed, reason}}

          {:ok, card} ->
            # 4. Fraud screening
            fraud_result = FraudScore.evaluate(%{
              card_fingerprint: card.fingerprint,
              ip_address:       intent.metadata[:ip_address],
              amount_cents:     intent.amount_cents,
              customer_id:      intent.customer_id
            })

            case fraud_result do
              {:error, _} ->
                Logger.warning("Fraud scoring unavailable — proceeding with caution")

              {:ok, %{score: score}} when score >= @fraud_block_score ->
                Logger.warning("Charge blocked — fraud score #{score} for customer #{intent.customer_id}")
                {:error, :fraud_suspected}

              _ ->
                :ok
            end

            # 5. Select appropriate gateway
            gateway =
              cond do
                intent.currency == "brl"          -> :pagarme
                intent.amount_cents > 1_000_000   -> :braintree
                card.network in ["amex", "jcb"]   -> :adyen
                true                              -> :stripe
              end

            # 6. Attempt charge with retries
            charge_result =
              Enum.reduce_while(0..@max_retries, {:error, :not_attempted}, fn attempt, _acc ->
                if attempt > 0 do
                  Logger.info("Retry attempt #{attempt} for intent #{intent.id} via #{gateway}")
                  Process.sleep(attempt * 500)
                end

                case Gateway.charge(gateway, %{
                  amount_cents:    intent.amount_cents,
                  currency:        intent.currency,
                  card:            card,
                  description:     intent.description,
                  capture_method:  capture_method,
                  metadata:        intent.metadata
                }) do
                  {:ok, gateway_txn} ->
                    {:halt, {:ok, gateway_txn}}

                  {:error, %{retryable: true} = reason} when attempt < @max_retries ->
                    Logger.warning("Retryable error on attempt #{attempt}: #{inspect(reason)}")
                    {:cont, {:error, reason}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end
              end)

            case charge_result do
              {:error, reason} ->
                Logger.error("Charge failed for intent #{intent.id}: #{inspect(reason)}")
                {:error, {:charge_failed, reason}}

              {:ok, gateway_txn} ->
                # 7. Persist charge record
                charge_record = %ChargeRecord{
                  intent_id:        intent.id,
                  customer_id:      intent.customer_id,
                  gateway:          to_string(gateway),
                  gateway_txn_id:   gateway_txn.id,
                  amount_cents:     intent.amount_cents,
                  currency:         intent.currency,
                  status:           :succeeded,
                  idempotency_key:  idempotency_key,
                  capture_method:   capture_method,
                  charged_at:       DateTime.utc_now()
                }

                {:ok, saved_record} = ChargeRecord.insert(charge_record)

                # 8. Generate and e-mail receipt
                receipt = Receipt.build(saved_record, intent.customer_email)

                case Receipt.deliver(receipt) do
                  {:ok, _}         -> Logger.info("Receipt sent to #{intent.customer_email}")
                  {:error, reason} -> Logger.warning("Receipt delivery failed: #{inspect(reason)}")
                end

                # 9. Dispatch webhook asynchronously
                Task.start(fn ->
                  WebhookDispatcher.dispatch("charge.succeeded", %{
                    charge_id:  saved_record.id,
                    amount:     intent.amount_cents,
                    currency:   intent.currency,
                    customer:   intent.customer_id
                  })
                end)

                {:ok, saved_record}
            end
        end
    end
  end
end
```
