```elixir
defmodule EventStore.StoredEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stream_id: String.t(),
          stream_version: non_neg_integer(),
          event_type: String.t(),
          data: map(),
          metadata: map(),
          occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "stored_events" do
    field :stream_id, :string
    field :stream_version, :integer
    field :event_type, :string
    field :data, :map
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, params) do
    event
    |> cast(params, [:stream_id, :stream_version, :event_type, :data, :metadata, :occurred_at])
    |> validate_required([:stream_id, :stream_version, :event_type, :data])
    |> unique_constraint([:stream_id, :stream_version],
      name: :stored_events_stream_id_stream_version_index
    )
  end
end

defmodule EventStore do
  @moduledoc """
  An append-only event store with per-stream versioning and optimistic concurrency.

  Each append operation specifies the expected stream version; a mismatch
  indicates a concurrent writer and surfaces as `{:error, :version_conflict}`
  rather than silently overwriting data. Events within a stream are always
  returned in version order.
  """

  import Ecto.Query, warn: false

  alias EventStore.{Repo, StoredEvent}

  @type stream_id :: String.t()
  @type expected_version :: non_neg_integer() | :any | :no_stream

  @spec append(stream_id(), [map()], expected_version()) ::
          {:ok, non_neg_integer()} | {:error, :version_conflict | term()}
  def append(stream_id, events, expected_version)
      when is_binary(stream_id) and is_list(events) do
    Repo.transaction(fn ->
      current = current_version(stream_id)

      case check_version(current, expected_version) do
        :ok ->
          next_version = (current || -1) + 1
          insert_events(stream_id, events, next_version)

        {:error, :version_conflict} ->
          Repo.rollback(:version_conflict)
      end
    end)
  end

  @spec read_stream(stream_id(), non_neg_integer()) :: [StoredEvent.t()]
  def read_stream(stream_id, from_version \\ 0)
      when is_binary(stream_id) and is_integer(from_version) do
    StoredEvent
    |> where([e], e.stream_id == ^stream_id and e.stream_version >= ^from_version)
    |> order_by([e], asc: e.stream_version)
    |> Repo.all()
  end

  @spec stream_version(stream_id()) :: non_neg_integer() | nil
  def stream_version(stream_id) when is_binary(stream_id) do
    current_version(stream_id)
  end

  defp current_version(stream_id) do
    StoredEvent
    |> where([e], e.stream_id == ^stream_id)
    |> select([e], max(e.stream_version))
    |> Repo.one()
  end

  defp check_version(_current, :any), do: :ok
  defp check_version(nil, :no_stream), do: :ok
  defp check_version(nil, expected) when is_integer(expected), do: {:error, :version_conflict}
  defp check_version(current, :no_stream) when not is_nil(current), do: {:error, :version_conflict}
  defp check_version(current, expected) when current == expected, do: :ok
  defp check_version(_current, _expected), do: {:error, :version_conflict}

  defp insert_events(stream_id, events, first_version) do
    now = DateTime.utc_now()

    events
    |> Enum.with_index(first_version)
    |> Enum.each(fn {event, version} ->
      %StoredEvent{}
      |> StoredEvent.changeset(%{
        stream_id: stream_id,
        stream_version: version,
        event_type: event.type,
        data: event.data,
        metadata: Map.get(event, :metadata, %{}),
        occurred_at: now
      })
      |> Repo.insert!()
    end)

    first_version + length(events) - 1
  end
end
```
