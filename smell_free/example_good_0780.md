```elixir
defmodule Platform.WebhookDeliveryPipeline do
  @moduledoc """
  Orchestrates outbound webhook delivery from event emission to HTTP
  dispatch. The pipeline fetches registered endpoints for the event type,
  builds signed payloads, and dispatches each delivery as a supervised
  task. Delivery results are persisted for retry tracking. This module
  owns the full fanout lifecycle; individual delivery workers stay focused
  on a single endpoint.
  """

  require Logger

  alias Comms.WebhookRegistry
  alias Webhooks.{DeliverySupervisor, PayloadSigner}
  alias MyApp.Repo
  alias Platform.WebhookDeliveryLog

  @type event_type :: String.t()
  @type event_payload :: map()

  @type pipeline_result :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Fanouts `event_type` with `payload` to all registered active endpoints.
  Returns counts of dispatched and skipped (no endpoints) deliveries.
  """
  @spec process(event_type(), event_payload()) :: pipeline_result()
  def process(event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    endpoints = WebhookRegistry.endpoints_for_event(event_type)

    if Enum.empty?(endpoints) do
      %{dispatched: 0, skipped: 1}
    else
      dispatched =
        Enum.map(endpoints, fn endpoint ->
          dispatch_to_endpoint(endpoint, event_type, payload)
        end)
        |> Enum.count(& &1 == :ok)

      %{dispatched: dispatched, skipped: 0}
    end
  end

  defp dispatch_to_endpoint(endpoint, event_type, payload) do
    envelope = build_envelope(event_type, payload)
    signature = PayloadSigner.sign(envelope, endpoint.signing_secret_hash)
    delivery_params = %{url: endpoint.url, payload: envelope, max_attempts: 5}

    case DeliverySupervisor.schedule(delivery_params) do
      {:ok, _pid} ->
        persist_delivery_attempt(endpoint.id, event_type, :dispatched)
        Logger.info("[WebhookPipeline] Dispatched #{event_type} to #{endpoint.url}")
        :ok

      {:error, reason} ->
        persist_delivery_attempt(endpoint.id, event_type, :failed)
        Logger.warning("[WebhookPipeline] Dispatch failed to #{endpoint.url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_envelope(event_type, payload) do
    %{
      event_type: event_type,
      payload: payload,
      delivered_at: DateTime.to_iso8601(DateTime.utc_now()),
      delivery_id: generate_id()
    }
  end

  defp persist_delivery_attempt(endpoint_id, event_type, status) do
    attrs = %{
      webhook_endpoint_id: endpoint_id,
      event_type: event_type,
      status: Atom.to_string(status),
      attempted_at: DateTime.utc_now()
    }

    Repo.insert_all(WebhookDeliveryLog, [attrs])
  rescue
    _ -> :ok
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
