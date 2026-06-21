```elixir
defmodule Platform.Outbox do
  @moduledoc """
  Transactional outbox context for reliable domain event publishing.

  Events are written to the `outbox_messages` table inside the same Ecto
  transaction as the business operation that produced them. A separate
  poller process reads and publishes unpublished events, guaranteeing
  at-least-once delivery without dual-write race conditions.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Platform.{Repo, Outbox.Message}

  @type event_name :: String.t()
  @type payload :: map()

  @doc """
  Appends an outbox message to an existing `Ecto.Multi` pipeline.
  The message is inserted in the same transaction as the surrounding operation.
  """
  @spec append_to_multi(Multi.t(), atom(), event_name(), payload()) :: Multi.t()
  def append_to_multi(%Multi{} = multi, step_name, event_name, payload)
      when is_binary(event_name) and is_map(payload) do
    attrs = %{event_name: event_name, payload: payload, status: :pending, inserted_at: DateTime.utc_now()}
    Multi.insert(multi, step_name, Message.changeset(%Message{}, attrs))
  end

  @doc """
  Fetches a batch of unpublished messages, ordered by insertion time.
  Used by the poller to claim messages for delivery.
  """
  @spec claim_pending(pos_integer()) :: [Message.t()]
  def claim_pending(limit \\ 50) when is_integer(limit) and limit > 0 do
    from(m in Message,
      where: m.status == :pending,
      order_by: [asc: m.inserted_at],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.all()
  end

  @doc "Marks a message as published after successful delivery."
  @spec mark_published(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def mark_published(%Message{} = message) do
    message
    |> Message.publish_changeset(%{status: :published, published_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Marks a message as failed with a reason string."
  @spec mark_failed(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%Message{} = message, reason) when is_binary(reason) do
    message
    |> Message.publish_changeset(%{status: :failed, failure_reason: reason})
    |> Repo.update()
  end
end

defmodule Platform.Outbox.Poller do
  @moduledoc """
  A GenServer that periodically polls the outbox table and publishes
  pending messages to the configured event bus.
  """

  use GenServer

  require Logger

  alias Platform.Outbox
  alias Platform.EventBus

  @default_poll_interval_ms 2_000
  @default_batch_size 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    schedule_poll(interval)
    {:ok, %{interval: interval, batch_size: batch_size}}
  end

  @impl GenServer
  def handle_info(:poll, %{batch_size: batch_size, interval: interval} = state) do
    process_batch(batch_size)
    schedule_poll(interval)
    {:noreply, state}
  end

  defp process_batch(batch_size) do
    messages = Outbox.claim_pending(batch_size)

    Enum.each(messages, fn message ->
      case EventBus.publish(message.event_name, message.payload) do
        :ok ->
          Outbox.mark_published(message)

        {:error, reason} ->
          Logger.warning("[Outbox.Poller] Publish failed",
            event: message.event_name,
            id: message.id,
            reason: inspect(reason)
          )
          Outbox.mark_failed(message, inspect(reason))
      end
    end)
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
```
