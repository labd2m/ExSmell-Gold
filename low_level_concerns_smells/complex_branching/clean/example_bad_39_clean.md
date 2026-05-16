# Example 39

```elixir
defmodule Eventing.StreamPublisher do
  @moduledoc """
  Publishes domain events to the StreamBus event streaming platform.
  Used by all bounded contexts to emit events for downstream consumers.
  """

  require Logger

  alias Eventing.Repo
  alias Eventing.Schema.{PublishedEvent, EventTopic}
  alias Eventing.StreamBus.Client
  alias Eventing.DeadLetterQueue

  @max_payload_bytes 1_048_576
  @supported_encodings [:json, :avro, :protobuf]

  def publish(topic_name, event_type, payload, opts \\ []) do
    encoding = Keyword.get(opts, :encoding, :json)
    partition_key = Keyword.get(opts, :partition_key)

    with {:ok, topic} <- fetch_topic(topic_name),
         :ok <- validate_encoding(encoding),
         :ok <- check_payload_size(payload),
         {:ok, encoded} <- encode_payload(payload, encoding) do
      publish_event(
        topic,
        Client.post("/topics/#{topic.stream_id}/events", %{
          type: event_type,
          payload: encoded,
          encoding: encoding,
          partition_key: partition_key
        })
      )
    end
  end

  defp fetch_topic(name) do
    case Repo.get_by(EventTopic, name: name) do
      nil -> {:error, :topic_not_found}
      t -> {:ok, t}
    end
  end

  defp validate_encoding(enc) when enc in @supported_encodings, do: :ok
  defp validate_encoding(_), do: {:error, :unsupported_encoding}

  defp check_payload_size(payload) do
    size = :erlang.external_size(payload)
    if size > @max_payload_bytes, do: {:error, :payload_too_large}, else: :ok
  end

  defp encode_payload(payload, :json), do: Jason.encode(payload)
  defp encode_payload(payload, _), do: {:ok, payload}

  defp publish_event(topic, stream_response) do
    case stream_response do
      {:ok, %{status: 201, body: %{"event_id" => eid, "offset" => offset, "partition" => part}}} ->
        Logger.debug("Event #{eid} published to topic #{topic.name}, partition #{part}, offset #{offset}")

        Repo.insert(%PublishedEvent{
          topic_id: topic.id,
          event_id: eid,
          partition: part,
          offset: offset,
          status: :published
        })

        {:ok, %{event_id: eid, offset: offset, partition: part}}

      {:ok, %{status: 202, body: %{"event_id" => eid, "status" => "buffered", "estimated_delay_ms" => delay}}} ->
        Logger.info("Event #{eid} buffered on topic #{topic.name}, estimated delay #{delay}ms")

        Repo.insert(%PublishedEvent{
          topic_id: topic.id,
          event_id: eid,
          status: :buffered
        })

        {:ok, %{event_id: eid, status: :buffered, estimated_delay_ms: delay}}

      {:ok, %{status: 400, body: %{"error" => "schema_validation_failed", "violations" => violations}}} ->
        Logger.warning("Schema validation failed on topic #{topic.name}: #{inspect(violations)}")
        {:error, {:schema_invalid, violations}}

      {:ok, %{status: 400, body: %{"error" => "event_type_not_registered"}}} ->
        Logger.warning("Event type not registered on topic #{topic.name}")
        {:error, :event_type_not_registered}

      {:ok, %{status: 404, body: %{"error" => "topic_not_found"}}} ->
        Logger.error("Topic #{topic.name} not found on StreamBus — may have been deleted")
        {:error, :remote_topic_not_found}

      {:ok, %{status: 409, body: %{"error" => "partition_key_conflict"}}} ->
        Logger.warning("Partition key conflict on topic #{topic.name}")
        {:error, :partition_key_conflict}

      {:ok, %{status: 413, body: _}} ->
        Logger.warning("Payload too large rejected by StreamBus for topic #{topic.name}")
        {:error, :payload_too_large}

      {:ok, %{status: 429, body: %{"error" => "throughput_exceeded", "retry_after_ms" => ms}}} ->
        Logger.warning("Throughput exceeded on topic #{topic.name}, retry after #{ms}ms")
        DeadLetterQueue.enqueue(topic, ms)
        {:error, {:throughput_exceeded, ms}}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by StreamBus for topic #{topic.name}")
        {:error, :rate_limited}

      {:ok, %{status: 503, body: _}} ->
        Logger.error("StreamBus broker unavailable for topic #{topic.name}")
        DeadLetterQueue.enqueue(topic, 5_000)
        {:error, :broker_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected StreamBus response #{status} for topic #{topic.name}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("StreamBus timeout for topic #{topic.name}")
        {:error, :publish_timeout}

      {:error, reason} ->
        Logger.error("StreamBus connection error for topic #{topic.name}: #{inspect(reason)}")
        {:error, {:stream_error, reason}}
    end
  end

  def topic_stats(topic_name) do
    case fetch_topic(topic_name) do
      {:ok, topic} ->
        Client.get("/topics/#{topic.stream_id}/stats")

      err ->
        err
    end
  end
end
```
