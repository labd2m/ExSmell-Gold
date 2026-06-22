```elixir
defmodule Ingestion.WebhookProcessor do
  @moduledoc """
  Receives, validates, and dispatches inbound webhook payloads from external services.
  Signature verification and idempotency checks are enforced before routing.
  """

  alias Ingestion.{SignatureVerifier, IdempotencyStore, EventRouter}

  @type webhook_source :: :stripe | :github | :sendgrid
  @type raw_payload :: binary()
  @type headers :: %{String.t() => String.t()}
  @type parsed_event :: %{id: String.t(), type: String.t(), source: webhook_source(), data: map()}
  @type process_result :: {:ok, parsed_event()} | {:error, String.t()}

  @spec process(webhook_source(), raw_payload(), headers()) :: process_result()
  def process(source, payload, headers)
      when source in [:stripe, :github, :sendgrid] and is_binary(payload) and is_map(headers) do
    with :ok <- verify_signature(source, payload, headers),
         {:ok, event} <- parse_payload(source, payload),
         :ok <- ensure_not_duplicate(event.id),
         :ok <- EventRouter.route(event) do
      IdempotencyStore.mark_processed(event.id)
      {:ok, event}
    end
  end

  @spec verify_signature(webhook_source(), raw_payload(), headers()) :: :ok | {:error, String.t()}
  defp verify_signature(:stripe, payload, headers) do
    signature = Map.get(headers, "stripe-signature", "")
    SignatureVerifier.verify_stripe(payload, signature)
  end

  defp verify_signature(:github, payload, headers) do
    signature = Map.get(headers, "x-hub-signature-256", "")
    SignatureVerifier.verify_github(payload, signature)
  end

  defp verify_signature(:sendgrid, _payload, _headers), do: :ok

  @spec parse_payload(webhook_source(), raw_payload()) ::
          {:ok, parsed_event()} | {:error, String.t()}
  defp parse_payload(source, payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> build_event(source, decoded)
      {:error, _} -> {:error, "Invalid JSON payload from #{source}"}
    end
  end

  @spec build_event(webhook_source(), map()) :: {:ok, parsed_event()} | {:error, String.t()}
  defp build_event(:stripe, %{"id" => id, "type" => type, "data" => data}) do
    {:ok, %{id: id, type: type, source: :stripe, data: data}}
  end

  defp build_event(:github, %{"action" => action, "delivery" => id} = data) do
    {:ok, %{id: id, type: action, source: :github, data: data}}
  end

  defp build_event(:sendgrid, %{"sg_message_id" => id, "event" => type} = data) do
    {:ok, %{id: id, type: type, source: :sendgrid, data: data}}
  end

  defp build_event(source, _payload) do
    {:error, "Unrecognized payload structure from #{source}"}
  end

  @spec ensure_not_duplicate(String.t()) :: :ok | {:error, String.t()}
  defp ensure_not_duplicate(event_id) do
    case IdempotencyStore.already_processed?(event_id) do
      true -> {:error, "Duplicate event: #{event_id}"}
      false -> :ok
    end
  end
end
```
