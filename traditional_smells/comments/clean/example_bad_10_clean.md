```elixir
defmodule WebhookProcessor do
  @moduledoc """
  Handles incoming webhook events from external providers, performing
  signature verification, idempotency checks, and event-type routing.
  """

  alias WebhookProcessor.{
    SignatureVerifier,
    IdempotencyLog,
    EventRouter,
    DeadLetterQueue,
    WebhookEvent
  }

  @supported_providers ~w(stripe github pagerduty sendgrid)
  @max_payload_bytes 524_288

  @doc """
  Returns true if the provider name is in the list of supported webhook providers.
  """
  def supported_provider?(provider), do: provider in @supported_providers

  @doc """
  Fetches the processing result for a previously seen event by its external event ID.
  """
  def find_processed_event(provider, event_id) do
    IdempotencyLog.fetch(provider, event_id)
  end

  # process_event/2
  #
  # Validates and routes an incoming webhook payload from `provider`.
  #
  # Processing pipeline:
  #   1. Reject oversized payloads (> @max_payload_bytes).
  #   2. Verify HMAC signature using SignatureVerifier. The raw_signature
  #      is typically extracted from the provider-specific header
  #      (e.g. "Stripe-Signature", "X-Hub-Signature-256").
  #   3. Check IdempotencyLog to skip already-processed event IDs.
  #   4. Decode and validate the payload JSON into a WebhookEvent struct.
  #   5. Route to the appropriate handler via EventRouter based on
  #      `provider` and `event.type`.
  #   6. Persist the result in IdempotencyLog.
  #
  # On unrecoverable processing errors the raw payload is forwarded to
  # DeadLetterQueue for manual review.
  #
  # Parameters:
  #   provider - string provider name (must be in @supported_providers)
  #   context  - map with keys:
  #                :raw_body       - binary request body
  #                :raw_signature  - binary signature header value
  #                :received_at    - DateTime of receipt
  #
  # Returns {:ok, result} | {:error, :duplicate} | {:error, reason}.
  # multi-step pipeline and context map shape through plain inline comments
  # rather than @doc, making the documentation inaccessible to ExDoc and IEx.
  def process_event(provider, context) do
    %{raw_body: raw_body, raw_signature: raw_signature, received_at: received_at} = context

    with :ok <- validate_provider(provider),
         :ok <- check_payload_size(raw_body),
         :ok <- SignatureVerifier.verify(provider, raw_body, raw_signature),
         {:ok, event} <- WebhookEvent.decode(provider, raw_body, received_at),
         {:ok, :new} <- IdempotencyLog.check(provider, event.id),
         {:ok, result} <- EventRouter.route(provider, event) do
      IdempotencyLog.record(provider, event.id, result)
      {:ok, result}
    else
      {:ok, :duplicate} ->
        {:error, :duplicate}

      {:error, reason} = err ->
        DeadLetterQueue.enqueue(provider, raw_body, reason)
        err
    end
  end

  @doc """
  Replays a dead-letter entry after manual inspection and correction.
  """
  def replay_dead_letter(dead_letter_id) do
    with {:ok, entry} <- DeadLetterQueue.fetch(dead_letter_id),
         {:ok, result} <- process_event(entry.provider, entry.context) do
      DeadLetterQueue.mark_replayed(dead_letter_id)
      {:ok, result}
    end
  end

  defp validate_provider(provider) when provider in @supported_providers, do: :ok
  defp validate_provider(provider), do: {:error, {:unsupported_provider, provider}}

  defp check_payload_size(body) when byte_size(body) <= @max_payload_bytes, do: :ok
  defp check_payload_size(_), do: {:error, :payload_too_large}
end
```
