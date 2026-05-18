# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `BillingEventProcessor.normalize_event/1`, line where `String.to_atom/1` is called on the event type |
| **Affected function(s)** | `BillingEventProcessor.normalize_event/1` |
| **Short explanation** | The event `"type"` field originates from an external billing webhook payload (e.g., Stripe). Converting it with `String.to_atom/1` means every novel event type string seen at runtime becomes a permanent atom, leaking memory until the atom table limit is reached. |

```elixir
defmodule MyApp.BillingEventProcessor do
  @moduledoc """
  Processes incoming billing webhook events from the payment provider.
  Events are normalized into internal structs and persisted before being
  forwarded to downstream subscribers.
  """

  require Logger

  alias MyApp.Billing.{Event, EventStore, Notifier}
  alias MyApp.Accounts

  @supported_events ~w(
    invoice.created
    invoice.paid
    invoice.payment_failed
    subscription.created
    subscription.updated
    subscription.deleted
    customer.created
    customer.updated
  )

  @doc """
  Entry point for a raw webhook payload map decoded from JSON.
  Returns `{:ok, event}` on success or `{:error, reason}` on failure.
  """
  @spec process(map()) :: {:ok, Event.t()} | {:error, term()}
  def process(%{"type" => type} = raw) when type in @supported_events do
    Logger.info("Processing billing event", type: type)

    with {:ok, event} <- normalize_event(raw),
         {:ok, _} <- EventStore.insert(event),
         :ok <- Notifier.broadcast(event) do
      Logger.info("Billing event processed", event_id: event.id)
      {:ok, event}
    else
      {:error, reason} = err ->
        Logger.error("Failed to process billing event", reason: inspect(reason), type: type)
        err
    end
  end

  def process(%{"type" => type}) do
    Logger.warning("Received unsupported billing event type", type: type)
    {:error, {:unsupported_event, type}}
  end

  def process(_raw) do
    {:error, :invalid_payload}
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is used to convert the
  # `"type"` field from the external webhook payload into an atom. Even though there
  # is a guard clause above that restricts processing to known types, this private
  # function does not enforce that constraint itself and could be refactored or
  # called from other paths in the future. More importantly, the pattern establishes
  # the habit of converting external strings to atoms dynamically, which is unsafe.
  defp normalize_event(%{"type" => type, "id" => external_id, "data" => data, "created" => ts}) do
    event = %Event{
      id: MyApp.UUID.generate(),
      external_id: external_id,
      type: String.to_atom(type),
      data: data,
      occurred_at: DateTime.from_unix!(ts),
      inserted_at: DateTime.utc_now()
    }

    {:ok, event}
  end
  # VALIDATION: SMELL END

  defp normalize_event(_), do: {:error, :malformed_event}

  defp enrich_event(%Event{data: %{"object" => %{"customer" => customer_id}}} = event) do
    case Accounts.find_by_external_id(customer_id) do
      {:ok, account} -> {:ok, %{event | account_id: account.id}}
      {:error, :not_found} -> {:ok, event}
    end
  end

  defp enrich_event(event), do: {:ok, event}
end
```
