```elixir
defmodule Integrations.WebhookDispatcher do
  @moduledoc """
  Dispatches outbound webhook payloads to registered subscriber endpoints.

  Each dispatch attempt is made with configurable retry logic using
  exponential backoff. Delivery receipts are recorded regardless of
  outcome for observability and manual replay purposes.
  """

  alias Integrations.WebhookSubscription
  alias Integrations.DeliveryReceipt
  alias Integrations.HttpClient

  @max_attempts 4
  @base_backoff_ms 500

  @type event_type :: atom()
  @type payload :: map()

  @type dispatch_outcome ::
          {:ok, DeliveryReceipt.t()}
          | {:error, :all_attempts_exhausted, DeliveryReceipt.t()}

  @doc """
  Dispatches a webhook event to all active subscriptions for the event type.

  Each subscription receives an independent delivery attempt with retries.
  Returns a list of per-subscription outcomes.
  """
  @spec dispatch_event(event_type(), payload()) :: [dispatch_outcome()]
  def dispatch_event(event_type, payload) when is_atom(event_type) and is_map(payload) do
    subscriptions = WebhookSubscription.active_for_event(event_type)
    Enum.map(subscriptions, &deliver_with_retry(&1, event_type, payload))
  end

  @doc """
  Attempts delivery to a single subscription with exponential backoff retries.
  """
  @spec deliver_with_retry(WebhookSubscription.t(), event_type(), payload()) ::
          dispatch_outcome()
  def deliver_with_retry(subscription, event_type, payload) do
    attempt_delivery(subscription, event_type, payload, 1)
  end

  @spec attempt_delivery(WebhookSubscription.t(), event_type(), payload(), pos_integer()) ::
          dispatch_outcome()
  defp attempt_delivery(subscription, event_type, payload, attempt) when attempt <= @max_attempts do
    signed_payload = sign_payload(payload, subscription.secret)

    case HttpClient.post(subscription.endpoint_url, signed_payload, delivery_headers()) do
      {:ok, %{status: status}} when status in 200..299 ->
        receipt = record_receipt(subscription, event_type, :delivered, attempt)
        {:ok, receipt}

      {:ok, %{status: status}} ->
        backoff_and_retry(subscription, event_type, payload, attempt, {:http_error, status})

      {:error, reason} ->
        backoff_and_retry(subscription, event_type, payload, attempt, reason)
    end
  end

  defp attempt_delivery(subscription, event_type, _payload, attempt) do
    receipt = record_receipt(subscription, event_type, :failed, attempt)
    {:error, :all_attempts_exhausted, receipt}
  end

  @spec backoff_and_retry(
          WebhookSubscription.t(),
          event_type(),
          payload(),
          pos_integer(),
          term()
        ) :: dispatch_outcome()
  defp backoff_and_retry(subscription, event_type, payload, attempt, _reason) do
    delay = @base_backoff_ms * :math.pow(2, attempt - 1) |> round()
    Process.sleep(delay)
    attempt_delivery(subscription, event_type, payload, attempt + 1)
  end

  @spec sign_payload(payload(), String.t()) :: map()
  defp sign_payload(payload, secret) when is_binary(secret) do
    body = Jason.encode!(payload)
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.hex_encode32(case: :lower)
    Map.put(payload, :_signature, signature)
  end

  @spec delivery_headers() :: [{String.t(), String.t()}]
  defp delivery_headers do
    [
      {"Content-Type", "application/json"},
      {"X-Webhook-Source", "myapp"}
    ]
  end

  @spec record_receipt(WebhookSubscription.t(), event_type(), atom(), pos_integer()) ::
          DeliveryReceipt.t()
  defp record_receipt(subscription, event_type, status, attempts) do
    attrs = %{
      subscription_id: subscription.id,
      event_type: event_type,
      status: status,
      attempt_count: attempts,
      recorded_at: DateTime.utc_now()
    }

    {:ok, receipt} = DeliveryReceipt.create(attrs)
    receipt
  end
end
```
