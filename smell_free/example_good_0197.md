# File: `example_good_197.md`

```elixir
defmodule Events.OutboxPublisher do
  @moduledoc """
  GenServer that implements the transactional outbox pattern for reliable
  event publishing.

  Domain events are written to an `outbox_messages` table within the
  same database transaction as the originating domain change. This
  publisher polls the table periodically, forwards unpublished messages
  to the configured broker, and marks them as delivered.

  This guarantees at-least-once delivery without distributed transactions.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias Events.{OutboxMessage, Repo}

  @default_poll_interval_ms 2_000
  @default_batch_size 50
  @lock_timeout_ms 5_000

  @type opts :: [
          broker: module(),
          poll_interval_ms: pos_integer(),
          batch_size: pos_integer()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns publishing statistics for the current process lifetime.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init(opts) do
    broker = Keyword.fetch!(opts, :broker)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok, %{broker: broker, poll_interval_ms: poll_interval_ms,
            batch_size: batch_size, published: 0, failed: 0}}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:published, :failed]), state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = process_batch(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  defp process_batch(state) do
    messages = fetch_pending_batch(state.batch_size)

    {published, failed} =
      Enum.reduce(messages, {0, 0}, fn msg, {ok_count, err_count} ->
        publish_message(msg, state.broker)
        |> tally_result(ok_count, err_count)
      end)

    %{state | published: state.published + published, failed: state.failed + failed}
  end

  defp fetch_pending_batch(batch_size) do
    OutboxMessage
    |> where([m], m.status == :pending)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^batch_size)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp publish_message(%OutboxMessage{} = message, broker) do
    Repo.transaction(fn ->
      with :ok <- broker.publish(message.topic, message.payload, message.headers),
           {:ok, _} <- mark_delivered(message) do
        :ok
      else
        {:error, reason} ->
          mark_failed(message, reason)
          {:error, reason}
      end
    end, timeout: @lock_timeout_ms)
  end

  defp mark_delivered(%OutboxMessage{} = message) do
    message
    |> OutboxMessage.delivery_changeset(%{status: :delivered, delivered_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp mark_failed(%OutboxMessage{} = message, reason) do
    error_detail = inspect(reason) |> String.slice(0, 500)

    message
    |> OutboxMessage.failure_changeset(%{
      status: :failed,
      last_error: error_detail,
      attempt_count: message.attempt_count + 1
    })
    |> Repo.update()
  end

  defp tally_result({:ok, _}, ok_count, err_count), do: {ok_count + 1, err_count}
  defp tally_result({:error, _}, ok_count, err_count), do: {ok_count, err_count + 1}

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
```
