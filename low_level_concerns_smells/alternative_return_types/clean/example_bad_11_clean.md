```elixir
defmodule MyApp.Webhooks.Processor do
  @moduledoc """
  Processes inbound webhook payloads from external providers (payment gateways,
  shipping carriers, CRM systems). Validates signatures, routes events to
  domain handlers, and optionally records audit logs.
  """

  alias MyApp.Webhooks.SignatureVerifier
  alias MyApp.Webhooks.EventRouter
  alias MyApp.Webhooks.AuditLog
  alias MyApp.Webhooks.RetryQueue

  @supported_providers [:stripe, :correios, :hubspot, :twilio]
  @max_payload_bytes 1_048_576

  def parse_headers(headers) do
    %{
      provider: headers["x-provider"],
      signature: headers["x-signature"],
      event_type: headers["x-event-type"],
      delivered_at: headers["x-timestamp"]
    }
  end

  def handle(payload, opts \\ []) when is_list(opts) do
    respond_with = Keyword.get(opts, :respond_with, :simple)
    provider = Keyword.get(opts, :provider)
    enqueue_on_failure = Keyword.get(opts, :enqueue_on_failure, false)
    headers = Keyword.get(opts, :headers, %{})

    if byte_size(payload) > @max_payload_bytes do
      {:error, :payload_too_large}
    else
      with {:ok, decoded} <- Jason.decode(payload),
           :ok <- verify_signature(provider, decoded, headers["x-signature"]),
           {:ok, event} <- EventRouter.route(provider, decoded) do
        result = EventRouter.dispatch(event)

        case respond_with do
          :simple ->
            case result do
              {:ok, _} -> :ok
              {:error, reason} ->
                if enqueue_on_failure, do: RetryQueue.enqueue(payload, provider)
                {:error, reason}
            end

          :ack ->
            case result do
              {:ok, _} ->
                {:ok, %{received: true, event_id: event.id, provider: provider}}

              {:error, reason} ->
                if enqueue_on_failure, do: RetryQueue.enqueue(payload, provider)
                {:error, reason}
            end

          :audit ->
            entry = AuditLog.build(provider, event, result)
            AuditLog.persist(entry)

            case result do
              {:ok, _} -> {:ok, entry}
              {:error, _} ->
                if enqueue_on_failure, do: RetryQueue.enqueue(payload, provider)
                {:error, entry}
            end
        end
      end
    end
  end

  def replay(event_id, provider) do
    with {:ok, raw} <- AuditLog.fetch_payload(event_id),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, event} <- EventRouter.route(provider, decoded) do
      EventRouter.dispatch(event)
    end
  end

  def list_failures(provider, since \\ nil) do
    AuditLog.list(provider: provider, status: :error, since: since)
  end

  defp verify_signature(provider, payload, signature) do
    case SignatureVerifier.verify(provider, payload, signature) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end
end
```
