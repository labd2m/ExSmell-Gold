```elixir
defprotocol Events.Serializable do
  @moduledoc """
  Converts a domain event struct into a Kafka-ready envelope. Implementing
  this protocol for each event type decouples message format decisions from
  business logic. The envelope includes the event type, schema version,
  partition key, and JSON-encoded payload so consumers can route, filter,
  and decode messages without inspecting the body.
  """

  @doc "Returns the Kafka topic this event should be published to."
  @spec topic(t()) :: binary()
  def topic(event)

  @doc "Returns the partition key used for ordering guarantees."
  @spec partition_key(t()) :: binary()
  def partition_key(event)

  @doc "Returns the schema version string for forward-compatibility tracking."
  @spec schema_version(t()) :: binary()
  def schema_version(event)

  @doc "Returns the payload as a JSON-encodable map."
  @spec to_payload(t()) :: map()
  def to_payload(event)
end

defmodule Events.KafkaPublisher do
  @moduledoc """
  Publishes domain events to Kafka by delegating serialisation to the
  `Events.Serializable` protocol. Wraps every event in a typed envelope
  before encoding so consumers receive consistent metadata alongside the
  domain payload.
  """

  require Logger

  @type publish_result :: :ok | {:error, term()}

  @doc """
  Publishes `event` to the Kafka topic declared by its `Serializable` implementation.
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec publish(Events.Serializable.t()) :: publish_result()
  def publish(event) do
    topic = Events.Serializable.topic(event)
    key = Events.Serializable.partition_key(event)
    envelope = build_envelope(event)

    case Jason.encode(envelope) do
      {:ok, json} ->
        send_to_kafka(topic, key, json)

      {:error, reason} ->
        Logger.error("Failed to encode event", event: inspect(event), reason: inspect(reason))
        {:error, {:encode_failed, reason}}
    end
  end

  @doc """
  Publishes a list of events transactionally in a single Kafka produce request.
  All events must target the same topic; mixed-topic batches are rejected.
  """
  @spec publish_batch([Events.Serializable.t()]) :: publish_result()
  def publish_batch([]), do: :ok

  def publish_batch([first | _] = events) do
    topic = Events.Serializable.topic(first)

    if Enum.all?(events, &(Events.Serializable.topic(&1) == topic)) do
      messages =
        Enum.map(events, fn event ->
          key = Events.Serializable.partition_key(event)
          {:ok, json} = build_envelope(event) |> Jason.encode()
          %{key: key, value: json}
        end)

      Kafka.Producer.produce_batch(topic, messages)
    else
      {:error, :mixed_topics_in_batch}
    end
  end

  defp build_envelope(event) do
    %{
      event_type: event.__struct__ |> Module.split() |> List.last(),
      schema_version: Events.Serializable.schema_version(event),
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: Events.Serializable.to_payload(event)
    }
  end

  defp send_to_kafka(topic, key, json) do
    case Kafka.Producer.produce(topic, key, json) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Kafka publish failed", topic: topic, reason: inspect(reason))
        {:error, reason}
    end
  end
end

defmodule Commerce.Events.OrderPlaced do
  @moduledoc false

  @enforce_keys [:order_id, :customer_id, :total_cents, :currency, :occurred_at]
  defstruct [:order_id, :customer_id, :total_cents, :currency, :items, :occurred_at]

  defimpl Events.Serializable do
    def topic(_event), do: "commerce.orders"
    def partition_key(event), do: event.customer_id
    def schema_version(_event), do: "1.0"

    def to_payload(event) do
      %{
        order_id: event.order_id,
        customer_id: event.customer_id,
        total_cents: event.total_cents,
        currency: event.currency,
        item_count: length(event.items || []),
        occurred_at: DateTime.to_iso8601(event.occurred_at)
      }
    end
  end
end

defmodule Accounts.Events.UserVerified do
  @moduledoc false

  @enforce_keys [:user_id, :email, :occurred_at]
  defstruct [:user_id, :email, :occurred_at]

  defimpl Events.Serializable do
    def topic(_event), do: "accounts.users"
    def partition_key(event), do: event.user_id
    def schema_version(_event), do: "1.0"

    def to_payload(event) do
      %{
        user_id: event.user_id,
        email_domain: event.email |> String.split("@") |> List.last(),
        occurred_at: DateTime.to_iso8601(event.occurred_at)
      }
    end
  end
end
```
