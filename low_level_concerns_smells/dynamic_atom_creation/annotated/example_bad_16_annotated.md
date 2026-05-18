# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `WebhookRouter.route/1`, line where `String.to_atom/1` converts the webhook event topic |
| **Affected function(s)** | `WebhookRouter.route/1` |
| **Short explanation** | The webhook router receives events from multiple third-party SaaS platforms. Each platform uses its own event naming convention, and the topic string is converted to an atom to dispatch to the correct handler module. Any new event topic introduced by any platform—or any misconfigured platform—will silently create a new permanent atom. |

```elixir
defmodule MyApp.Webhooks.WebhookRouter do
  @moduledoc """
  Routes incoming webhook payloads from external SaaS platforms to the
  appropriate domain handler. Supports Stripe, GitHub, Sendgrid, PagerDuty,
  and custom internal webhook sources.
  """

  require Logger

  alias MyApp.Webhooks.{SignatureVerifier, WebhookLog}

  @handler_registry %{
    "stripe" => MyApp.Webhooks.Handlers.Stripe,
    "github" => MyApp.Webhooks.Handlers.GitHub,
    "sendgrid" => MyApp.Webhooks.Handlers.Sendgrid,
    "pagerduty" => MyApp.Webhooks.Handlers.PagerDuty
  }

  @doc """
  Routes a raw webhook request to the appropriate handler.
  The `conn` map contains `:source`, `:headers`, `:raw_body`, and `:parsed_body`.
  """
  @spec route(map()) :: {:ok, map()} | {:error, term()}
  def route(%{source: source, raw_body: raw_body, headers: headers, parsed_body: body} = conn) do
    request_id = generate_request_id()
    Logger.metadata(webhook_request_id: request_id, source: source)
    Logger.info("Incoming webhook", source: source)

    with :ok <- SignatureVerifier.verify(source, raw_body, headers),
         {:ok, handler} <- find_handler(source),
         {:ok, event} <- extract_event(body, source),
         {:ok, result} <- dispatch(handler, event) do
      WebhookLog.record(:success, request_id, source, event)
      {:ok, result}
    else
      {:error, :signature_invalid} = err ->
        Logger.warning("Webhook signature verification failed", source: source)
        WebhookLog.record(:rejected, request_id, source, nil)
        err

      {:error, reason} = err ->
        Logger.error("Webhook routing failed", source: source, reason: inspect(reason))
        WebhookLog.record(:error, request_id, source, nil)
        err
    end
  end

  defp find_handler(source) do
    case Map.fetch(@handler_registry, source) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, {:unknown_source, source}}
    end
  end

  defp extract_event(%{"event" => event_type} = body, _source) do
    {:ok, %{type: event_type, data: Map.get(body, "data", %{}), raw: body}}
  end

  defp extract_event(%{"action" => action} = body, _source) do
    {:ok, %{type: action, data: body, raw: body}}
  end

  defp extract_event(_, _), do: {:error, :missing_event_type}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` converts the event type
  # string—which originates from an external SaaS platform's webhook payload—into
  # an atom before dispatching. Different platforms use different naming conventions
  # (e.g., "payment_intent.succeeded", "push", "group_unsubscribe", "resolve"),
  # and platforms may add new event types at any time. Each unique event type string
  # permanently occupies an atom slot. A high-volume webhook endpoint receiving
  # events from many sources will accumulate atoms silently over its lifetime.
  defp dispatch(handler, %{type: event_type} = event) do
    action = String.to_atom(event_type)

    if function_exported?(handler, action, 1) do
      Logger.debug("Dispatching webhook event", handler: handler, action: action)
      apply(handler, action, [event.data])
    else
      Logger.info("No handler for event type, ignoring", type: event_type, handler: handler)
      {:ok, :ignored}
    end
  end
  # VALIDATION: SMELL END

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
