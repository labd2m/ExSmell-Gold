```elixir
defmodule EventBus do
  @moduledoc """
  Unified event publishing interface for the platform's event-driven architecture.
  Supports Kafka topic publication, real-time WebSocket broadcasting,
  and outbound webhook delivery.
  """

  alias EventBus.{
    KafkaEvent,
    WebSocketBroadcast,
    WebhookDelivery,
    KafkaProducer,
    SocketRegistry,
    WebhookQueue,
    EventStore,
    DeadLetterQueue
  }

  require Logger

  @doc """
  Publish an event to the appropriate delivery channel.

  Accepts a `%KafkaEvent{}`, `%WebSocketBroadcast{}`, or `%WebhookDelivery{}`
  and delivers the event payload to the corresponding channel.

  ## Examples

      iex> EventBus.publish(%KafkaEvent{topic: "orders.created", payload: %{order_id: "ord_1"}})
      {:ok, %{offset: 1042, partition: 3}}

  """
  def publish(%KafkaEvent{
        topic: topic,
        key: key,
        payload: payload,
        headers: headers,
        partition_strategy: partition_strategy
      }) do
    encoded_payload = Jason.encode!(payload)

    kafka_message = %{
      topic: topic,
      key: key || "default",
      value: encoded_payload,
      headers: headers,
      timestamp: System.os_time(:millisecond)
    }

    with {:ok, metadata} <- KafkaProducer.produce(kafka_message, partition: partition_strategy),
         :ok <-
           EventStore.record(%{
             channel: :kafka,
             topic: topic,
             key: key,
             payload: payload,
             offset: metadata.offset,
             partition: metadata.partition,
             published_at: DateTime.utc_now()
           }) do
      Logger.debug("Kafka event published to #{topic} partition=#{metadata.partition} offset=#{metadata.offset}")
      {:ok, %{offset: metadata.offset, partition: metadata.partition}}
    else
      {:error, reason} ->
        Logger.error("Kafka publish failed for topic #{topic}: #{inspect(reason)}")
        DeadLetterQueue.enqueue(:kafka, kafka_message, reason)
        {:error, reason}
    end
  end

  # publish real-time event to connected WebSocket clients
  def publish(%WebSocketBroadcast{
        room: room,
        event_name: event_name,
        payload: payload,
        exclude_user_id: exclude_user_id
      }) do
    recipients = SocketRegistry.list_connections(room, exclude: exclude_user_id)

    if Enum.empty?(recipients) do
      Logger.debug("WebSocket broadcast to #{room}: no connected clients")
      {:ok, %{sent_to: 0}}
    else
      results =
        Enum.map(recipients, fn socket ->
          SocketRegistry.push(socket.pid, event_name, payload)
        end)

      sent = Enum.count(results, &(&1 == :ok))
      failed = length(results) - sent

      Logger.debug("WebSocket broadcast #{event_name} to room #{room}: #{sent} sent, #{failed} failed")
      {:ok, %{sent_to: sent, failed: failed}}
    end
  end

  # publish webhook delivery to external subscriber endpoint
  def publish(%WebhookDelivery{
        subscription_id: subscription_id,
        endpoint_url: url,
        event_type: event_type,
        payload: payload,
        secret: secret,
        attempt: attempt
      })
      when attempt >= 1 do
    signature = compute_hmac_signature(payload, secret)
    encoded = Jason.encode!(payload)

    job = %{
      subscription_id: subscription_id,
      url: url,
      event_type: event_type,
      body: encoded,
      headers: %{
        "Content-Type" => "application/json",
        "X-Webhook-Event" => to_string(event_type),
        "X-Webhook-Signature" => "sha256=#{signature}",
        "X-Webhook-Attempt" => to_string(attempt)
      },
      attempt: attempt,
      scheduled_at: backoff_time(attempt)
    }

    with {:ok, job_id} <- WebhookQueue.enqueue(job),
         :ok <-
           EventStore.record(%{
             channel: :webhook,
             subscription_id: subscription_id,
             event_type: event_type,
             job_id: job_id,
             attempt: attempt,
             published_at: DateTime.utc_now()
           }) do
      Logger.info("Webhook job #{job_id} queued for #{url} (attempt #{attempt})")
      {:ok, %{job_id: job_id, scheduled_at: job.scheduled_at}}
    end
  end

  defp compute_hmac_signature(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, Jason.encode!(payload))
    |> Base.encode16(case: :lower)
  end

  defp backoff_time(1), do: DateTime.utc_now()
  defp backoff_time(attempt) do
    delay = :math.pow(2, attempt - 1) |> round()
    DateTime.add(DateTime.utc_now(), delay, :second)
  end
end
```
