```elixir
defmodule Outbox.Entry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :delivered | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          topic: String.t(),
          payload: map(),
          status: status(),
          attempts: non_neg_integer(),
          last_error: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "outbox_entries" do
    field :topic, :string
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :delivered, :failed], default: :pending
    field :attempts, :integer, default: 0
    field :last_error, :string
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, params) do
    entry
    |> cast(params, [:topic, :payload])
    |> validate_required([:topic, :payload])
    |> validate_length(:topic, min: 1, max: 255)
  end
end

defmodule Outbox.Publisher do
  @moduledoc """
  Polls the outbox table and delivers pending entries to Phoenix.PubSub.

  Writing domain events to the outbox table inside the same database
  transaction as the state change guarantees that events are never lost,
  even when the application crashes between state change and publish.
  The publisher sweeps pending rows on a configurable interval and marks
  each entry as delivered or failed based on the broadcast result.
  """

  use GenServer

  require Logger

  alias Outbox.{Entry, Repo}
  import Ecto.Query, warn: false

  @type opts :: [poll_interval_ms: pos_integer(), pubsub: atom(), batch_size: pos_integer()]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(Ecto.Multi.t(), String.t(), map()) :: Ecto.Multi.t()
  def enqueue(%Ecto.Multi{} = multi, topic, payload) when is_binary(topic) and is_map(payload) do
    changeset = Entry.changeset(%Entry{}, %{topic: topic, payload: payload})
    Ecto.Multi.insert(multi, {:outbox, topic}, changeset)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
      pubsub: Keyword.get(opts, :pubsub, MyApp.PubSub),
      batch_size: Keyword.get(opts, :batch_size, 50)
    }

    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    pending_entries = fetch_pending(state.batch_size)
    Enum.each(pending_entries, &deliver(&1, state.pubsub))
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  defp fetch_pending(limit) do
    Entry
    |> where([e], e.status == :pending)
    |> order_by([e], asc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp deliver(%Entry{} = entry, pubsub) do
    case Phoenix.PubSub.broadcast(pubsub, entry.topic, {:outbox_event, entry.payload}) do
      :ok ->
        Repo.update_all(
          from(e in Entry, where: e.id == ^entry.id),
          set: [status: :delivered]
        )

      {:error, reason} ->
        Logger.warning("Outbox delivery failed", topic: entry.topic, reason: inspect(reason))

        Repo.update_all(
          from(e in Entry, where: e.id == ^entry.id),
          inc: [attempts: 1],
          set: [last_error: inspect(reason)]
        )
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
```
