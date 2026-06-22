```elixir
defmodule Messaging.OutboxPublisher do
  @moduledoc """
  Implements the transactional outbox pattern for reliable event publishing.
  Domain events are written to an outbox table within the same database
  transaction as the business operation, then forwarded to a message broker
  by a periodic polling process.
  """

  use GenServer

  alias Messaging.{Repo, OutboxEntry, BrokerClient}
  import Ecto.Query

  @poll_interval_ms 2_000
  @batch_size 50

  @type event :: %{
          topic: String.t(),
          key: String.t(),
          payload: map(),
          headers: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec stage(event(), Ecto.Multi.t()) :: Ecto.Multi.t()
  def stage(event, multi) do
    entry_params = %{
      topic: event.topic,
      key: event.key,
      payload: event.payload,
      headers: event.headers,
      status: :pending
    }

    Ecto.Multi.insert(multi, {:outbox, event.key}, OutboxEntry.creation_changeset(%OutboxEntry{}, entry_params))
  end

  @spec flush() :: {:ok, non_neg_integer()}
  def flush do
    GenServer.call(__MODULE__, :flush, 15_000)
  end

  @impl GenServer
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:ok, count} = publish_pending_batch()
    {:reply, {:ok, count}, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    publish_pending_batch()
    schedule_poll()
    {:noreply, state}
  end

  @spec publish_pending_batch() :: {:ok, non_neg_integer()}
  defp publish_pending_batch do
    entries = fetch_pending_entries()

    published =
      Enum.reduce(entries, 0, fn entry, count ->
        case publish_entry(entry) do
          :ok -> count + 1
          {:error, _} -> count
        end
      end)

    {:ok, published}
  end

  @spec fetch_pending_entries() :: [OutboxEntry.t()]
  defp fetch_pending_entries do
    from(e in OutboxEntry,
      where: e.status == :pending,
      order_by: [asc: e.inserted_at],
      limit: @batch_size,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.all()
  end

  @spec publish_entry(OutboxEntry.t()) :: :ok | {:error, term()}
  defp publish_entry(entry) do
    event = %{
      topic: entry.topic,
      key: entry.key,
      payload: entry.payload,
      headers: entry.headers
    }

    case BrokerClient.publish(event) do
      :ok ->
        mark_published(entry)
        :ok

      {:error, reason} ->
        mark_failed(entry, reason)
        {:error, reason}
    end
  end

  @spec mark_published(OutboxEntry.t()) :: :ok
  defp mark_published(entry) do
    entry
    |> OutboxEntry.status_changeset(:published, %{published_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  @spec mark_failed(OutboxEntry.t(), term()) :: :ok
  defp mark_failed(entry, reason) do
    entry
    |> OutboxEntry.status_changeset(:failed, %{failure_reason: inspect(reason)})
    |> Repo.update()

    :ok
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```
