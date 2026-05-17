# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Events.WebhookRouter.route/1`, around the `String.to_atom/1` call on untrusted input
- **Affected function(s):** `route/1`
- **Short explanation:** The function converts the event type string from the webhook payload into an atom using `String.to_atom/1`. If the event type is absent or has an unexpected format, `String.to_atom/1` succeeds anyway — it creates the atom silently (atom table is not garbage collected). More critically, if the event type string happens to match no handler, the function falls through to a catch-all that returns `:ignored` without error, silently dropping real events like `"payment.captured"` that were misspelled or sent in an unexpected format.

---

```elixir
defmodule Events.WebhookRouter do
  @moduledoc """
  Routes incoming webhook events from external partners to the appropriate
  domain handlers. Supports events from payment processors, logistics
  carriers, and communication platforms.

  Event payload format:
    {
      "event_type": "payment.captured",
      "source":     "stripe",
      "id":         "evt_abc123",
      "timestamp":  "2024-03-15T14:22:00Z",
      "payload":    { ... }
    }
  """

  require Logger

  alias Events.Handlers.{Payment, Logistics, Communication, Subscription}

  @handler_map %{
    payment_captured:        {Payment, :handle_capture},
    payment_failed:          {Payment, :handle_failure},
    payment_refunded:        {Payment, :handle_refund},
    shipment_dispatched:     {Logistics, :handle_dispatch},
    shipment_delivered:      {Logistics, :handle_delivery},
    shipment_exception:      {Logistics, :handle_exception},
    message_delivered:       {Communication, :handle_delivery},
    message_failed:          {Communication, :handle_failure},
    subscription_created:    {Subscription, :handle_creation},
    subscription_cancelled:  {Subscription, :handle_cancellation},
    subscription_renewed:    {Subscription, :handle_renewal}
  }

  def process_batch(raw_events) when is_list(raw_events) do
    raw_events
    |> Enum.map(&decode_event/1)
    |> Enum.reject(&match?({:error, _}, &1))
    |> Enum.map(fn {:ok, event} -> route(event) end)
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function calls String.to_atom/1 on the
  # VALIDATION: event_type string, which comes from an untrusted external webhook payload.
  # VALIDATION: String.to_atom/1 never raises — it silently creates a new atom even
  # VALIDATION: for completely unexpected strings (e.g., "payment.captured" should be
  # VALIDATION: "payment_captured" — with underscores, not dots). Since "payment.captured"
  # VALIDATION: as an atom does not exist in @handler_map, the function silently returns
  # VALIDATION: {:ok, :ignored} rather than {:error, :unknown_event}. Real financial
  # VALIDATION: events are silently dropped, the system believes they were handled,
  # VALIDATION: and no crash or structured error alerts the team to the format mismatch.
  def route(%{event_type: type_string} = event) do
    handler_key = String.to_atom(String.replace(type_string, ".", "_"))

    case Map.get(@handler_map, handler_key) do
      {module, function} ->
        Logger.debug("Routing event #{type_string} to #{module}.#{function}")

        try do
          apply(module, function, [event])
        rescue
          e ->
            Logger.error("Handler error for #{type_string}: #{inspect(e)}")
            {:error, :handler_failed}
        end

      nil ->
        Logger.debug("No handler for event type: #{type_string}")
        {:ok, :ignored}
    end
  end
  # VALIDATION: SMELL END

  def route(_), do: {:error, :invalid_event}

  defp decode_event(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"event_type" => type, "source" => src, "id" => id, "payload" => payload}} ->
        {:ok, %{
          event_type: type,
          source:     src,
          id:         id,
          payload:    payload,
          received_at: DateTime.utc_now()
        }}

      {:ok, _} ->
        {:error, :missing_required_fields}

      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  defp decode_event(_), do: {:error, :invalid_raw_event}

  def routing_summary(results) do
    %{
      total:   length(results),
      ignored: Enum.count(results, &match?({:ok, :ignored}, &1)),
      failed:  Enum.count(results, &match?({:error, _}, &1)),
      handled: Enum.count(results, fn
        {:ok, :ignored} -> false
        {:ok, _}        -> true
        _               -> false
      end)
    }
  end

  def registered_events do
    Map.keys(@handler_map) |> Enum.map(&Atom.to_string/1)
  end
end
```
