**File:** `example_good_1407.md`

```elixir
defmodule Outbox.Message do
  @moduledoc "Schema representing a pending outbox message awaiting publication."

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :published | :failed
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          event_type: String.t(),
          aggregate_id: String.t(),
          aggregate_type: String.t(),
          payload: map(),
          status: status(),
          attempt: non_neg_integer(),
          last_error: String.t() | nil,
          publish_after: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "outbox_messages" do
    field :event_type, :string
    field :aggregate_id, :string
    field :aggregate_type, :string
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :published, :failed]
    field :attempt, :integer, default: 0
    field :last_error, :string
    field :publish_after, :utc_datetime_usec
    timestamps()
  end

  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(msg, attrs) do
    msg
    |> cast(attrs, [:event_type, :aggregate_id, :aggregate_type, :payload, :publish_after])
    |> validate_required([:event_type, :aggregate_id, :aggregate_type, :payload])
    |> put_change(:status, :pending)
    |> put_change(:publish_after, Map.get(attrs, :publish_after, DateTime.utc_now()))
  end
end

defmodule Outbox.Publisher do
  @moduledoc "Behaviour for backends that publish outbox messages externally."

  alias Outbox.Message

  @doc "Publishes a single message. Returns :ok or {:error, reason}."
  @callback publish(Message.t()) :: :ok | {:error, term()}
end

defmodule Outbox.Poller do
  @moduledoc """
  A GenServer that polls the outbox table for pending messages and
  attempts to publish them via the configured backend. Marks messages
  as published or failed accordingly.
  """

  use GenServer

  require Logger

  alias Outbox.Message
  alias MyApp.Repo

  import Ecto.Query

  @default_poll_interval_ms :timer.seconds(5)
  @default_batch_size 50
  @max_attempts 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      publisher: Keyword.fetch!(opts, :publisher),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size)
    }

    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    fetch_and_publish(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  defp fetch_and_publish(%{publisher: publisher, batch_size: batch_size}) do
    now = DateTime.utc_now()

    messages =
      Message
      |> where([m], m.status == :pending and m.publish_after <= ^now)
      |> where([m], m.attempt < ^@max_attempts)
      |> order_by([m], asc: m.inserted_at)
      |> limit(^batch_size)
      |> Repo.all()

    Enum.each(messages, &attempt_publish(&1, publisher))
  end

  defp attempt_publish(%Message{} = msg, publisher) do
    case publisher.publish(msg) do
      :ok ->
        msg
        |> Ecto.Changeset.change(status: :published)
        |> Repo.update()

        Logger.debug("Outbox: published #{msg.event_type} for #{msg.aggregate_id}")

      {:error, reason} ->
        new_attempt = msg.attempt + 1
        new_status = if new_attempt >= @max_attempts, do: :failed, else: :pending

        msg
        |> Ecto.Changeset.change(
          status: new_status,
          attempt: new_attempt,
          last_error: inspect(reason),
          publish_after: backoff_datetime(new_attempt)
        )
        |> Repo.update()

        Logger.warning("Outbox: failed to publish #{msg.event_type}: #{inspect(reason)}")
    end
  end

  defp backoff_datetime(attempt) do
    delay_seconds = round(:math.pow(2, attempt) * 5)
    DateTime.add(DateTime.utc_now(), delay_seconds, :second)
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end

defmodule Outbox do
  @moduledoc "Context for appending outbox messages within an Ecto transaction."

  alias Outbox.Message
  alias MyApp.Repo

  @spec append(Ecto.Multi.t(), atom(), map()) :: Ecto.Multi.t()
  def append(%Ecto.Multi{} = multi, name, attrs) do
    Ecto.Multi.insert(multi, name, Message.insert_changeset(%Message{}, attrs))
  end

  @spec publish_now(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def publish_now(attrs) do
    %Message{}
    |> Message.insert_changeset(attrs)
    |> Repo.insert()
  end
end
```
