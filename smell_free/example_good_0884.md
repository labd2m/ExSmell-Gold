```elixir
defmodule Streaming.KafkaConsumer do
  @moduledoc """
  A supervised GenServer that consumes messages from a Kafka topic using
  the Brod client library. Partition assignments are tracked per-process
  so that rebalances are handled gracefully: in-flight processing of
  revoked partitions is allowed to complete before offsets are committed,
  preventing duplicate delivery caused by premature offset advancement.
  Telemetry events are emitted for lag, throughput, and processing latency.
  """

  use GenServer

  require Logger

  @type topic :: binary()
  @type partition :: non_neg_integer()
  @type offset :: non_neg_integer()

  @commit_interval_ms 5_000
  @telemetry_prefix [:streaming, :kafka, :consumer]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the set of partitions currently assigned to this consumer.
  """
  @spec assigned_partitions(atom() | pid()) :: [{topic(), partition()}]
  def assigned_partitions(consumer \\ __MODULE__) do
    GenServer.call(consumer, :assigned_partitions)
  end

  @doc """
  Returns the current committed offsets per assigned partition.
  """
  @spec committed_offsets(atom() | pid()) :: %{{topic(), partition()} => offset()}
  def committed_offsets(consumer \\ __MODULE__) do
    GenServer.call(consumer, :committed_offsets)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    group_id = Keyword.fetch!(opts, :group_id)
    handler = Keyword.fetch!(opts, :handler)
    client = Keyword.get(opts, :client, :kafka_client)

    state = %{
      topic: topic,
      group_id: group_id,
      handler: handler,
      client: client,
      assignments: %{},
      pending_offsets: %{},
      committed_offsets: %{}
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    config = consumer_config(state)

    case :brod.start_link_group_subscriber(
           state.client,
           state.group_id,
           [state.topic],
           config,
           _cb_module = __MODULE__,
           _cb_init_data = {self(), state.handler}
         ) do
      {:ok, subscriber_pid} ->
        schedule_commit()
        {:noreply, Map.put(state, :subscriber_pid, subscriber_pid)}

      {:error, reason} ->
        Logger.error("Failed to start Kafka consumer", topic: state.topic, reason: inspect(reason))
        {:stop, {:consumer_start_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:assigned_partitions, _from, state) do
    {:reply, Map.keys(state.assignments), state}
  end

  def handle_call(:committed_offsets, _from, state) do
    {:reply, state.committed_offsets, state}
  end

  @impl GenServer
  def handle_cast({:assignment, topic, partition, offset}, state) do
    key = {topic, partition}
    new_assignments = Map.put(state.assignments, key, offset)
    Logger.info("Partition assigned", topic: topic, partition: partition, initial_offset: offset)
    {:noreply, %{state | assignments: new_assignments}}
  end

  def handle_cast({:revocation, topic, partition}, state) do
    key = {topic, partition}
    commit_single(state, key)
    new_assignments = Map.delete(state.assignments, key)
    Logger.info("Partition revoked", topic: topic, partition: partition)
    {:noreply, %{state | assignments: new_assignments}}
  end

  def handle_cast({:message_processed, topic, partition, offset}, state) do
    key = {topic, partition}
    new_pending = Map.put(state.pending_offsets, key, offset + 1)
    emit_processing_metric(topic, partition)
    {:noreply, %{state | pending_offsets: new_pending}}
  end

  @impl GenServer
  def handle_info(:commit, state) do
    new_committed = commit_all_pending(state)
    schedule_commit()
    {:noreply, %{state | committed_offsets: new_committed, pending_offsets: %{}}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp commit_all_pending(%{pending_offsets: pending, client: client, group_id: group_id} = state) do
    Enum.reduce(pending, state.committed_offsets, fn {{topic, partition}, offset}, committed ->
      case :brod.commit_offsets(client, group_id, [{topic, partition, offset}]) do
        :ok ->
          Map.put(committed, {topic, partition}, offset)

        {:error, reason} ->
          Logger.warning("Offset commit failed",
            topic: topic, partition: partition, offset: offset, reason: inspect(reason))
          committed
      end
    end)
  end

  defp commit_single(state, {topic, partition} = key) do
    if offset = Map.get(state.pending_offsets, key) do
      :brod.commit_offsets(state.client, state.group_id, [{topic, partition, offset}])
    end
  end

  defp emit_processing_metric(topic, partition) do
    :telemetry.execute(@telemetry_prefix ++ [:message_processed], %{count: 1},
      %{topic: topic, partition: partition})
  end

  defp consumer_config(_state) do
    [
      offset_reset_policy: :reset_to_earliest,
      reconnect_cool_down_seconds: 2,
      max_bytes: 1_048_576
    ]
  end

  defp schedule_commit do
    Process.send_after(self(), :commit, @commit_interval_ms)
  end
end
```
