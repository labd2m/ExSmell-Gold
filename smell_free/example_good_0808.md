```elixir
defmodule MyApp.Events.EventSourcingStore do
  @moduledoc """
  A write-optimised event store backed by PostgreSQL. Events are appended
  in strict sequence per aggregate stream using an optimistic concurrency
  check on the `expected_version` parameter. Concurrent writers that
  conflict receive `{:error, :version_conflict}` rather than silently
  overwriting each other's events.

  Streams are identified by a `{aggregate_type, aggregate_id}` pair.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Events.StoredEvent

  @type aggregate_type :: String.t()
  @type aggregate_id :: String.t()
  @type stream_id :: {aggregate_type(), aggregate_id()}
  @type event_data :: %{required(:type) => String.t(), optional(atom()) => term()}
  @type version :: non_neg_integer()

  @doc """
  Appends `events` to the stream identified by `stream_id`. Uses
  optimistic concurrency: `expected_version` must match the current
  stream version or the append is rejected.

  Pass `expected_version: 0` when creating a new stream.
  """
  @spec append(stream_id(), [event_data()], version()) ::
          {:ok, version()} | {:error, :version_conflict} | {:error, term()}
  def append({agg_type, agg_id} = _stream_id, events, expected_version)
      when is_binary(agg_type) and is_binary(agg_id) and is_list(events) do
    Repo.transaction(fn ->
      current = current_version(agg_type, agg_id)

      if current != expected_version do
        Repo.rollback(:version_conflict)
      else
        {new_version, _} =
          Enum.reduce(events, {expected_version, nil}, fn event_data, {version, _} ->
            next = version + 1

            %StoredEvent{}
            |> StoredEvent.changeset(%{
              aggregate_type: agg_type,
              aggregate_id: agg_id,
              event_type: event_data.type,
              payload: Map.drop(event_data, [:type]),
              version: next,
              occurred_at: DateTime.utc_now()
            })
            |> Repo.insert!()

            {next, nil}
          end)

        new_version
      end
    end)
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, :version_conflict} -> {:error, :version_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all events for the stream from `from_version` onward,
  ordered by version ascending.
  """
  @spec read(stream_id(), version()) :: [StoredEvent.t()]
  def read({agg_type, agg_id}, from_version \\ 0) do
    StoredEvent
    |> where([e], e.aggregate_type == ^agg_type and e.aggregate_id == ^agg_id)
    |> where([e], e.version > ^from_version)
    |> order_by([e], asc: e.version)
    |> Repo.all()
  end

  @doc "Returns the current version of the stream, or 0 if it does not exist."
  @spec stream_version(stream_id()) :: version()
  def stream_version({agg_type, agg_id}) do
    current_version(agg_type, agg_id)
  end

  @doc """
  Returns the aggregate state by replaying all stream events through
  `reducer_fn`. `initial_state` is used as the seed.
  """
  @spec replay(stream_id(), term(), (StoredEvent.t(), term() -> term())) :: term()
  def replay(stream_id, initial_state, reducer_fn) when is_function(reducer_fn, 2) do
    stream_id
    |> read()
    |> Enum.reduce(initial_state, reducer_fn)
  end

  @spec current_version(aggregate_type(), aggregate_id()) :: version()
  defp current_version(agg_type, agg_id) do
    StoredEvent
    |> where([e], e.aggregate_type == ^agg_type and e.aggregate_id == ^agg_id)
    |> select([e], max(e.version))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
```
