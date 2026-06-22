```elixir
defmodule Platform.EventSourcingStore do
  @moduledoc """
  Append-only event store for domain aggregates. Events are written in
  optimistic-concurrency batches keyed by stream ID and expected version.
  A version conflict causes the append to be rejected so callers can
  reload the aggregate and retry. Subscribers receive new events via
  PubSub after each successful append.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Platform.{EventRecord, StreamRecord}

  @type stream_id :: String.t()
  @type version :: non_neg_integer()
  @type raw_event :: %{type: String.t(), data: map()}
  @type stored_event :: %{
          id: Ecto.UUID.t(),
          stream_id: stream_id(),
          version: version(),
          type: String.t(),
          data: map(),
          occurred_at: DateTime.t()
        }

  @pubsub_topic_prefix "event_store:"

  @doc """
  Appends `events` to `stream_id`. `expected_version` is the version the
  caller last read; returns `{:error, :version_conflict}` when another
  writer has advanced the stream since then.
  """
  @spec append(stream_id(), [raw_event()], version()) ::
          {:ok, [stored_event()]}
          | {:error, :version_conflict | Ecto.Changeset.t()}
  def append(stream_id, events, expected_version)
      when is_binary(stream_id) and is_list(events) and is_integer(expected_version) do
    Repo.transaction(fn ->
      current_version = lock_and_fetch_version(stream_id)

      if current_version != expected_version do
        Repo.rollback(:version_conflict)
      else
        stored = insert_events(stream_id, events, current_version)
        new_version = current_version + length(events)
        upsert_stream(stream_id, new_version)
        broadcast(stream_id, stored)
        stored
      end
    end)
  end

  @doc "Returns all events for `stream_id` in version order."
  @spec read(stream_id()) :: [stored_event()]
  def read(stream_id) when is_binary(stream_id) do
    from(e in EventRecord,
      where: e.stream_id == ^stream_id,
      order_by: [asc: e.version]
    )
    |> Repo.all()
    |> Enum.map(&to_stored_event/1)
  end

  @doc "Returns events for `stream_id` with version greater than `after_version`."
  @spec read_after(stream_id(), version()) :: [stored_event()]
  def read_after(stream_id, after_version)
      when is_binary(stream_id) and is_integer(after_version) do
    from(e in EventRecord,
      where: e.stream_id == ^stream_id and e.version > ^after_version,
      order_by: [asc: e.version]
    )
    |> Repo.all()
    |> Enum.map(&to_stored_event/1)
  end

  @doc "Returns the current version of `stream_id`, or 0 if the stream does not exist."
  @spec current_version(stream_id()) :: version()
  def current_version(stream_id) when is_binary(stream_id) do
    case Repo.get_by(StreamRecord, stream_id: stream_id) do
      nil -> 0
      %StreamRecord{version: v} -> v
    end
  end

  defp lock_and_fetch_version(stream_id) do
    result =
      from(s in StreamRecord,
        where: s.stream_id == ^stream_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case result do
      nil -> 0
      %StreamRecord{version: v} -> v
    end
  end

  defp insert_events(stream_id, events, base_version) do
    now = DateTime.utc_now()

    events
    |> Enum.with_index(base_version + 1)
    |> Enum.map(fn {event, version} ->
      attrs = %{
        id: Ecto.UUID.generate(),
        stream_id: stream_id,
        version: version,
        type: event.type,
        data: event.data,
        occurred_at: now
      }

      Repo.insert!(%EventRecord{} |> EventRecord.changeset(attrs))
      to_stored_event(attrs)
    end)
  end

  defp upsert_stream(stream_id, new_version) do
    Repo.insert_all(
      StreamRecord,
      [%{stream_id: stream_id, version: new_version, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:version, :updated_at]},
      conflict_target: :stream_id
    )
  end

  defp broadcast(stream_id, stored_events) do
    topic = @pubsub_topic_prefix <> stream_id
    Phoenix.PubSub.broadcast(MyApp.PubSub, topic, {:events_appended, stored_events})
  end

  defp to_stored_event(%EventRecord{} = r) do
    %{id: r.id, stream_id: r.stream_id, version: r.version,
      type: r.type, data: r.data, occurred_at: r.occurred_at}
  end

  defp to_stored_event(map) when is_map(map), do: map
end
```
