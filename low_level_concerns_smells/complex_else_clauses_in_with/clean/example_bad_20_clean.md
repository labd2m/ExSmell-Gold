```elixir
defmodule Webhooks.DeliveryService do
  alias Webhooks.{Repo, Endpoint, EventPayload, PayloadSigner, HTTPClient, DeliveryLog}

  require Logger

  @delivery_timeout_ms 10_000
  @max_payload_bytes 5_242_880

  def deliver_webhook(event, endpoint_id) do
    with {:ok, endpoint} <- fetch_active_endpoint(endpoint_id),
         :ok <- verify_target_url(endpoint.target_url),
         {:ok, payload} <- EventPayload.build(event, endpoint.api_version),
         :ok <- validate_payload_size(payload),
         {:ok, signed_payload} <- PayloadSigner.sign(payload, endpoint.secret),
         {:ok, response} <- HTTPClient.post(endpoint.target_url, signed_payload, @delivery_timeout_ms) do
      DeliveryLog.record(%{
        endpoint_id: endpoint_id,
        event_id: event.id,
        status: :delivered,
        http_status: response.status,
        delivered_at: DateTime.utc_now()
      })

      Logger.info(
        "Webhook delivered: endpoint=#{endpoint_id} event=#{event.id} " <>
          "status=#{response.status}"
      )

      {:ok, %{endpoint_id: endpoint_id, http_status: response.status}}
    else
      {:error, :not_found} ->
        Logger.warning("Webhook endpoint #{endpoint_id} not found")
        DeliveryLog.record_failure(endpoint_id, event.id, :endpoint_not_found)
        {:error, :endpoint_not_found}

      {:error, :disabled} ->
        Logger.info("Webhook endpoint #{endpoint_id} is disabled — skipping delivery")
        {:error, :endpoint_disabled}

      {:error, :url_invalid} ->
        Logger.warning("Invalid target URL for webhook endpoint #{endpoint_id}")
        DeliveryLog.record_failure(endpoint_id, event.id, :invalid_url)
        {:error, :configuration_error}

      {:error, :url_not_reachable} ->
        Logger.warning("Target URL not reachable for endpoint #{endpoint_id}")
        schedule_retry(endpoint_id, event)
        {:error, :endpoint_unreachable}

      {:error, {:build_error, reason}} ->
        Logger.error("Payload build failed for event #{event.id}: #{inspect(reason)}")
        DeliveryLog.record_failure(endpoint_id, event.id, :payload_build_error)
        {:error, :payload_error}

      {:error, :payload_too_large} ->
        Logger.warning("Payload exceeds size limit for endpoint #{endpoint_id}")
        DeliveryLog.record_failure(endpoint_id, event.id, :payload_too_large)
        {:error, :payload_too_large}

      {:error, :signing_error} ->
        Logger.error("Payload signing failed for endpoint #{endpoint_id}")
        DeliveryLog.record_failure(endpoint_id, event.id, :signing_error)
        {:error, :signing_failed}

      {:error, :http_timeout} ->
        Logger.warning("HTTP delivery timed out for endpoint #{endpoint_id}")
        DeliveryLog.record_failure(endpoint_id, event.id, :timeout)
        schedule_retry(endpoint_id, event)
        {:error, :delivery_timeout}

      {:error, :http_error} ->
        Logger.error("HTTP error during delivery to endpoint #{endpoint_id}")
        DeliveryLog.record_failure(endpoint_id, event.id, :http_error)
        {:error, :delivery_failed}

      {:error, :recipient_rejected} ->
        Logger.warning("Endpoint #{endpoint_id} returned a rejection status")
        DeliveryLog.record_failure(endpoint_id, event.id, :rejected)
        {:error, :delivery_rejected}
    end
  end

  defp fetch_active_endpoint(endpoint_id) do
    case Repo.get(Endpoint, endpoint_id) do
      nil -> {:error, :not_found}
      %Endpoint{enabled: false} -> {:error, :disabled}
      endpoint -> {:ok, endpoint}
    end
  end

  defp verify_target_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["https", "http"] -> {:error, :url_invalid}
      is_nil(uri.host) -> {:error, :url_invalid}
      true -> :ok
    end
  end

  defp validate_payload_size(payload) do
    size = byte_size(:erlang.term_to_binary(payload))

    if size <= @max_payload_bytes do
      :ok
    else
      {:error, :payload_too_large}
    end
  end

  defp schedule_retry(endpoint_id, event) do
    %{endpoint_id: endpoint_id, event_id: event.id}
    |> Webhooks.RetryWorker.new(schedule_in: 300)
    |> Oban.insert()
  end
end
```
