# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `parse_event_type/1` function, lines ~42–56
- **Affected function(s):** `parse_event_type/1`
- **Short explanation:** `parse_event_type/1` returns a generic `:unknown_event` atom instead of crashing when it receives an unrecognised event string. This speculative fallback silently lets unexpected event types flow through the notification pipeline, causing them to be silently dropped or mishandled rather than surfacing the problem to the supervisor.

---

```elixir
defmodule Notifications.EventProcessor do
  @moduledoc """
  Consumes raw webhook events from the event bus, classifies them, and
  dispatches the appropriate notification to the affected users.
  """

  require Logger

  alias Notifications.Dispatcher
  alias Notifications.Formatters

  @supported_events ~w(
    payment_received
    payment_failed
    subscription_renewed
    subscription_cancelled
    invoice_generated
    refund_issued
  )

  @doc """
  Entry point for processing a single raw event map received from the
  message broker.
  """
  def process(raw_event) when is_map(raw_event) do
    event_type = parse_event_type(Map.get(raw_event, "type"))
    payload    = Map.get(raw_event, "payload", %{})
    metadata   = build_metadata(raw_event)

    Logger.info("Processing event: #{event_type}")

    dispatch(event_type, payload, metadata)
  end

  @doc """
  Converts a raw event type string into an atom used for internal dispatch.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `parse_event_type/1` speculatively
  # returns `:unknown_event` for any string that is not in the list of
  # supported events, rather than crashing. The downstream `dispatch/3`
  # function has no planned clause for `:unknown_event`, so the event will
  # either be silently dropped or trigger an unrelated error much later in
  # the pipeline. The function gives a false impression of graceful handling
  # while actually swallowing unexpected input that should have caused a
  # controlled crash at the supervisor boundary.
  def parse_event_type(type) when is_binary(type) do
    if type in @supported_events do
      String.to_atom(type)
    else
      :unknown_event
    end
  end

  def parse_event_type(_), do: :unknown_event
  # VALIDATION: SMELL END

  defp dispatch(:payment_received, payload, meta),
    do: Dispatcher.send(Formatters.PaymentReceived.format(payload), meta)

  defp dispatch(:payment_failed, payload, meta),
    do: Dispatcher.send(Formatters.PaymentFailed.format(payload), meta)

  defp dispatch(:subscription_renewed, payload, meta),
    do: Dispatcher.send(Formatters.SubscriptionRenewed.format(payload), meta)

  defp dispatch(:subscription_cancelled, payload, meta),
    do: Dispatcher.send(Formatters.SubscriptionCancelled.format(payload), meta)

  defp dispatch(:invoice_generated, payload, meta),
    do: Dispatcher.send(Formatters.InvoiceGenerated.format(payload), meta)

  defp dispatch(:refund_issued, payload, meta),
    do: Dispatcher.send(Formatters.RefundIssued.format(payload), meta)

  defp build_metadata(raw_event) do
    %{
      event_id:   Map.fetch!(raw_event, "event_id"),
      account_id: Map.fetch!(raw_event, "account_id"),
      occurred_at: Map.fetch!(raw_event, "occurred_at"),
      source:      Map.get(raw_event, "source", "event_bus")
    }
  end

  @doc """
  Returns true if the given string corresponds to a supported event type.
  """
  def supported?(type) when is_binary(type), do: type in @supported_events
  def supported?(_), do: false
end
```
