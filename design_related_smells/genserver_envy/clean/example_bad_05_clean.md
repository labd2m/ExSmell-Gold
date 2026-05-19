```elixir
defmodule MyApp.PaymentAgent do
  @moduledoc """
  Handles payment intents, capture, and refund lifecycle for checkout flows.
  """

  use Agent

  alias MyApp.{Repo, GatewayClient, FraudScorer}
  alias MyApp.Payments.{Intent, Capture, Refund}

  @fraud_threshold 0.75

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          intents: %{},
          captures: %{},
          refunds: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def list_intents do
    Agent.get(__MODULE__, & &1.intents)
  end

  def list_captures do
    Agent.get(__MODULE__, & &1.captures)
  end


  def initiate_payment(order_id, amount_cents, currency) do
    Agent.get_and_update(__MODULE__, fn state ->
      fraud_score = FraudScorer.score(order_id)

      if fraud_score >= @fraud_threshold do
        {{:error, {:fraud_suspected, fraud_score}}, state}
      else
        case GatewayClient.create_intent(order_id, amount_cents, currency) do
          {:ok, gateway_ref} ->
            intent = %Intent{
              id: Ecto.UUID.generate(),
              order_id: order_id,
              amount_cents: amount_cents,
              currency: currency,
              gateway_ref: gateway_ref,
              status: :pending,
              fraud_score: fraud_score,
              created_at: DateTime.utc_now()
            }

            Repo.insert!(intent)
            new_state = put_in(state, [:intents, intent.id], intent)
            {{:ok, intent}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      end
    end)
  end

  def capture_payment(intent_id, idempotency_key) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.intents, intent_id) do
        :error ->
          {{:error, :intent_not_found}, state}

        {:ok, %Intent{status: :captured}} ->
          {{:error, :already_captured}, state}

        {:ok, intent} ->
          case GatewayClient.capture(intent.gateway_ref, idempotency_key) do
            {:ok, txn} ->
              capture = %Capture{
                id: Ecto.UUID.generate(),
                intent_id: intent_id,
                gateway_txn_id: txn.id,
                captured_at: DateTime.utc_now()
              }

              Repo.insert!(capture)
              updated_intent = %{intent | status: :captured}

              new_state =
                state
                |> put_in([:intents, intent_id], updated_intent)
                |> put_in([:captures, capture.id], capture)

              {{:ok, capture}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def refund(intent_id, amount_cents, reason) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, intent} <- Map.fetch(state.intents, intent_id),
           :captured <- intent.status,
           true <- amount_cents <= intent.amount_cents do
        case GatewayClient.refund(intent.gateway_ref, amount_cents) do
          {:ok, refund_ref} ->
            refund = %Refund{
              id: Ecto.UUID.generate(),
              intent_id: intent_id,
              amount_cents: amount_cents,
              reason: reason,
              gateway_ref: refund_ref,
              refunded_at: DateTime.utc_now()
            }

            Repo.insert!(refund)
            new_state = put_in(state, [:refunds, refund.id], refund)
            {{:ok, refund}, new_state}

          {:error, gw_reason} ->
            {{:error, gw_reason}, state}
        end
      else
        :error -> {{:error, :intent_not_found}, state}
        status when is_atom(status) -> {{:error, {:wrong_status, status}}, state}
        false -> {{:error, :refund_exceeds_capture}, state}
      end
    end)
  end

end
```
