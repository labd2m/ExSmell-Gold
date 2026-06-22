```elixir
defmodule Messaging.Outbox do
  @moduledoc """
  Implements the transactional outbox pattern for reliable message delivery.
  Messages are persisted atomically with the domain transaction and dispatched
  by a separate relay process, preventing dual-write inconsistencies.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Messaging.Repo

  @type status :: :pending | :dispatched | :failed

  schema "outbox_messages" do
    field :topic, :string
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :dispatched, :failed], default: :pending
    field :attempt_count, :integer, default: 0
    field :last_error, :string
    timestamps()
  end

  @doc "Changeset for enqueuing a new outbox message."
  @spec enqueue_changeset(map()) :: Ecto.Changeset.t()
  def enqueue_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:topic, :payload])
    |> validate_required([:topic, :payload])
    |> validate_length(:topic, min: 1, max: 255)
  end

  @doc "Fetches a batch of pending messages eligible for dispatch."
  @spec fetch_pending(pos_integer()) :: [t()]
  def fetch_pending(limit \\ 50) when is_integer(limit) and limit > 0 do
    from(m in __MODULE__,
      where: m.status == :pending and m.attempt_count < 5,
      order_by: [asc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Marks a message as successfully dispatched."
  @spec mark_dispatched(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_dispatched(%__MODULE__{} = msg) do
    msg
    |> change(status: :dispatched)
    |> Repo.update()
  end

  @doc "Records a dispatch failure and increments the attempt counter."
  @spec mark_failed(t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%__MODULE__{} = msg, error_message)
      when is_binary(error_message) do
    new_count = msg.attempt_count + 1
    new_status = if new_count >= 5, do: :failed, else: :pending

    msg
    |> change(status: new_status, attempt_count: new_count, last_error: error_message)
    |> Repo.update()
  end
end

defmodule Messaging.OutboxRelay do
  @moduledoc """
  Periodically polls the outbox for pending messages and dispatches them
  to the configured publisher. Runs as a supervised GenServer.
  """

  use GenServer
  require Logger

  alias Messaging.Outbox

  @default_poll_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    publisher = Keyword.fetch!(opts, :publisher)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    schedule_poll(poll_ms)
    {:ok, %{publisher: publisher, poll_ms: poll_ms}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Outbox.fetch_pending()
    |> Enum.each(&relay_message(&1, state.publisher))
    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp relay_message(msg, publisher) do
    case publisher.publish(msg.topic, msg.payload) do
      :ok ->
        Outbox.mark_dispatched(msg)
      {:error, reason} ->
        Logger.warning("Outbox dispatch failed", id: msg.id, reason: inspect(reason))
        Outbox.mark_failed(msg, inspect(reason))
    end
  end
end
```
