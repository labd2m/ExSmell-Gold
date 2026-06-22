```elixir
defmodule Messaging.Outbox do
  @moduledoc """
  Implements the transactional outbox pattern for reliable event publishing.

  Events are written to an outbox table in the same database transaction as
  the business operation. A separate relay process polls pending outbox entries
  and publishes them to the message broker, marking them delivered on success.
  """

  import Ecto.Query

  alias Messaging.Repo
  alias Messaging.Outbox.{OutboxEntry, Relay}

  @type publish_result :: {:ok, OutboxEntry.t()} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Writes an event to the outbox within the current database transaction.

  Must be called inside a `Repo.transaction/1` block alongside the business
  operation to ensure atomicity.
  """
  @spec enqueue(String.t(), map(), String.t()) :: publish_result()
  def enqueue(event_type, payload, idempotency_key)
      when is_binary(event_type) and is_map(payload) and is_binary(idempotency_key) do
    %OutboxEntry{}
    |> OutboxEntry.changeset(%{
      event_type: event_type,
      payload: payload,
      idempotency_key: idempotency_key,
      status: :pending
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key)
  end

  @doc """
  Fetches a batch of pending outbox entries for relay processing.
  """
  @spec fetch_pending(pos_integer()) :: [OutboxEntry.t()]
  def fetch_pending(batch_size) when is_integer(batch_size) and batch_size > 0 do
    OutboxEntry
    |> where([e], e.status == :pending)
    |> order_by([e], asc: e.inserted_at)
    |> limit(^batch_size)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  @doc """
  Marks an outbox entry as delivered after successful broker publication.
  """
  @spec mark_delivered(OutboxEntry.t()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def mark_delivered(%OutboxEntry{} = entry) do
    entry
    |> OutboxEntry.deliver_changeset(%{status: :delivered, delivered_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Marks an outbox entry as failed, incrementing the attempt count.
  """
  @spec mark_failed(OutboxEntry.t(), String.t()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def mark_failed(%OutboxEntry{} = entry, reason) when is_binary(reason) do
    new_attempts = entry.attempt_count + 1
    status = if new_attempts >= 5, do: :dead_letter, else: :pending

    entry
    |> OutboxEntry.fail_changeset(%{
      attempt_count: new_attempts,
      last_error: reason,
      status: status
    })
    |> Repo.update()
  end
end

defmodule Messaging.Outbox.Relay do
  @moduledoc """
  Supervised GenServer that polls the outbox and relays events to the broker.
  """

  use GenServer

  require Logger

  alias Messaging.Outbox
  alias Messaging.Outbox.OutboxEntry

  @poll_interval_ms 2_000
  @batch_size 50

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    broker = Keyword.fetch!(opts, :broker)
    schedule_poll()
    {:ok, %{broker: broker}}
  end

  @impl GenServer
  def handle_info(:poll, %{broker: broker} = state) do
    entries = Outbox.fetch_pending(@batch_size)
    Enum.each(entries, &relay_entry(&1, broker))
    schedule_poll()
    {:noreply, state}
  end

  defp relay_entry(%OutboxEntry{} = entry, broker) do
    case broker.publish(entry.event_type, entry.payload) do
      :ok ->
        Outbox.mark_delivered(entry)

      {:error, reason} ->
        Logger.warning("outbox relay failed for #{entry.idempotency_key}: #{reason}")
        Outbox.mark_failed(entry, reason)
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end

defmodule Messaging.Outbox.OutboxEntry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "outbox_entries" do
    field :event_type, :string
    field :payload, :map
    field :idempotency_key, :string
    field :status, Ecto.Enum, values: [:pending, :delivered, :dead_letter]
    field :attempt_count, :integer, default: 0
    field :last_error, :string
    field :delivered_at, :utc_datetime_usec
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:event_type, :payload, :idempotency_key, :status])
    |> validate_required([:event_type, :payload, :idempotency_key, :status])
    |> unique_constraint(:idempotency_key)
  end

  def deliver_changeset(entry, attrs) do
    cast(entry, attrs, [:status, :delivered_at])
  end

  def fail_changeset(entry, attrs) do
    cast(entry, attrs, [:attempt_count, :last_error, :status])
  end
end
```
