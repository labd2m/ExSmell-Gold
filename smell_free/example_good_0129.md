```elixir
defmodule MyApp.Webhooks.Processor do
  @moduledoc """
  Processes inbound webhook payloads from external payment and shipping
  providers. Each event type is dispatched to a dedicated handler function
  so that new event types can be added without modifying existing branches.

  Signature verification is performed before any payload parsing; malformed
  or tampered requests are rejected at the boundary with structured error
  tuples rather than raised exceptions.
  """

  alias MyApp.Webhooks.{SignatureVerifier, EventLog}
  alias MyApp.Commerce.Orders
  alias MyApp.Billing.Payments

  @type raw_payload :: binary()
  @type headers :: [{String.t(), String.t()}]
  @type provider :: :stripe | :shippo

  @doc """
  Entry point for all inbound webhooks. Verifies the provider signature,
  parses the payload, logs the event, and dispatches to the appropriate handler.
  """
  @spec process(provider(), raw_payload(), headers()) ::
          :ok | {:error, :invalid_signature} | {:error, :unsupported_event} | {:error, term()}
  def process(provider, payload, headers)
      when provider in [:stripe, :shippo] and is_binary(payload) do
    with :ok <- verify_signature(provider, payload, headers),
         {:ok, event} <- decode_payload(payload),
         :ok <- log_event(provider, event) do
      dispatch(provider, event)
    end
  end

  @spec verify_signature(provider(), raw_payload(), headers()) ::
          :ok | {:error, :invalid_signature}
  defp verify_signature(provider, payload, headers) do
    SignatureVerifier.verify(provider, payload, headers)
  end

  @spec decode_payload(raw_payload()) :: {:ok, map()} | {:error, :malformed_payload}
  defp decode_payload(payload) do
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :malformed_payload}
    end
  end

  @spec log_event(provider(), map()) :: :ok
  defp log_event(provider, event) do
    EventLog.record(%{
      provider: provider,
      event_type: Map.get(event, "type", "unknown"),
      raw: event,
      received_at: DateTime.utc_now()
    })
  end

  @spec dispatch(provider(), map()) ::
          :ok | {:error, :unsupported_event} | {:error, term()}
  defp dispatch(:stripe, %{"type" => "payment_intent.succeeded"} = event) do
    handle_payment_succeeded(event)
  end

  defp dispatch(:stripe, %{"type" => "payment_intent.payment_failed"} = event) do
    handle_payment_failed(event)
  end

  defp dispatch(:stripe, %{"type" => "charge.refunded"} = event) do
    handle_charge_refunded(event)
  end

  defp dispatch(:shippo, %{"event" => "track_updated"} = event) do
    handle_shipment_updated(event)
  end

  defp dispatch(_provider, _event), do: {:error, :unsupported_event}

  @spec handle_payment_succeeded(map()) :: :ok | {:error, term()}
  defp handle_payment_succeeded(event) do
    intent_id = get_in(event, ["data", "object", "id"])
    amount = get_in(event, ["data", "object", "amount"])
    Payments.confirm_by_provider_id(intent_id, amount)
  end

  @spec handle_payment_failed(map()) :: :ok | {:error, term()}
  defp handle_payment_failed(event) do
    intent_id = get_in(event, ["data", "object", "id"])
    reason = get_in(event, ["data", "object", "last_payment_error", "message"])
    Payments.mark_failed(intent_id, reason)
  end

  @spec handle_charge_refunded(map()) :: :ok | {:error, term()}
  defp handle_charge_refunded(event) do
    charge_id = get_in(event, ["data", "object", "id"])
    refund_amount = get_in(event, ["data", "object", "amount_refunded"])
    Payments.record_refund(charge_id, refund_amount)
  end

  @spec handle_shipment_updated(map()) :: :ok | {:error, term()}
  defp handle_shipment_updated(event) do
    tracking_number = get_in(event, ["data", "tracking_number"])
    status = get_in(event, ["data", "tracking_status", "status"])
    Orders.update_shipment_status(tracking_number, status)
  end
end
```
