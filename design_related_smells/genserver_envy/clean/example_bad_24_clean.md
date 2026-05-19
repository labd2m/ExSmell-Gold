```elixir
defmodule MyApp.MessageBrokerTask do
  @moduledoc """
  In-process pub/sub message broker for internal domain events.
  Supports topic subscriptions, message filtering, and delivery acknowledgements.
  """

  alias MyApp.{MetricsCollector, AuditLog}
  alias MyApp.Messaging.{Message, Subscription, DeliveryReceipt}

  @max_queue_depth 1_000
  @delivery_timeout_ms 5_000

  def start_broker(config) do
    Task.start_link(fn ->
      state = %{
        config: config,
        subscriptions: %{},
        topic_queues: %{},
        published_count: 0,
        dropped_count: 0
      }

      broker_loop(state)
    end)
  end

  defp broker_loop(state) do
    receive do
      {:subscribe, from, %Subscription{} = sub} ->
        existing = Map.get(state.subscriptions, sub.topic, [])

        if Enum.any?(existing, &(&1.subscriber_id == sub.subscriber_id)) do
          send(from, {:error, :already_subscribed})
          broker_loop(state)
        else
          new_subs = Map.put(state.subscriptions, sub.topic, [sub | existing])
          send(from, {:ok, sub.id})
          broker_loop(%{state | subscriptions: new_subs})
        end

      {:unsubscribe, from, topic, subscriber_id} ->
        updated =
          state.subscriptions
          |> Map.get(topic, [])
          |> Enum.reject(&(&1.subscriber_id == subscriber_id))

        new_subs = Map.put(state.subscriptions, topic, updated)
        send(from, :ok)
        broker_loop(%{state | subscriptions: new_subs})

      {:publish, from, %Message{} = msg} ->
        subscribers = Map.get(state.subscriptions, msg.topic, [])
        queue_depth = msg.topic |> then(&Map.get(state.topic_queues, &1, [])) |> length()

        if queue_depth >= @max_queue_depth do
          MetricsCollector.increment(:broker_drops)
          send(from, {:error, :queue_full})
          broker_loop(%{state | dropped_count: state.dropped_count + 1})
        else
          receipts =
            subscribers
            |> Enum.filter(fn sub ->
              is_nil(sub.filter) or sub.filter.(msg)
            end)
            |> Enum.map(fn sub ->
              send(sub.pid, {:message, msg})

              %DeliveryReceipt{
                message_id: msg.id,
                subscriber_id: sub.subscriber_id,
                delivered_at: DateTime.utc_now()
              }
            end)

          MetricsCollector.counter(:broker_published, 1)
          AuditLog.record(:message_published, %{topic: msg.topic, recipients: length(receipts)})
          send(from, {:ok, length(receipts)})
          broker_loop(%{state | published_count: state.published_count + 1})
        end

      {:get_subscribers, from, topic} ->
        subs = Map.get(state.subscriptions, topic, [])
        send(from, {:ok, subs})
        broker_loop(state)

      {:get_stats, from} ->
        stats = %{
          topics: map_size(state.subscriptions),
          total_subscribers:
            state.subscriptions |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
          published: state.published_count,
          dropped: state.dropped_count
        }
        send(from, {:ok, stats})
        broker_loop(state)

      {:purge_topic, from, topic} ->
        new_subs = Map.delete(state.subscriptions, topic)
        new_queues = Map.delete(state.topic_queues, topic)
        send(from, :ok)
        broker_loop(%{state | subscriptions: new_subs, topic_queues: new_queues})

      :stop ->
        :ok
    end
  end

  def subscribe(pid, subscription) do
    send(pid, {:subscribe, self(), subscription})

    receive do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    after
      @delivery_timeout_ms -> {:error, :timeout}
    end
  end

  def unsubscribe(pid, topic, subscriber_id) do
    send(pid, {:unsubscribe, self(), topic, subscriber_id})

    receive do
      :ok -> :ok
    after
      @delivery_timeout_ms -> {:error, :timeout}
    end
  end

  def publish(pid, message) do
    send(pid, {:publish, self(), message})

    receive do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    after
      @delivery_timeout_ms -> {:error, :timeout}
    end
  end

  def get_stats(pid) do
    send(pid, {:get_stats, self()})

    receive do
      {:ok, stats} -> {:ok, stats}
    after
      3_000 -> {:error, :timeout}
    end
  end
end
```
