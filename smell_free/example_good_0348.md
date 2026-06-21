```elixir
defmodule Platform.ReadModelProjector do
  @moduledoc """
  A GenServer that builds and maintains a denormalised read model by
  replaying domain events from the event store.

  Each projector subscribes to a specific stream, applies events in order
  to a projection function, and persists the result. On restart it resumes
  from the last-processed event version, enabling efficient catch-up.
  """

  use GenServer

  require Logger

  alias Platform.{EventStore, ReadModelProjector.Checkpoint}

  @type event :: %{event_type: String.t(), data: map(), stream_version: non_neg_integer()}
  @type projection_fn :: (term(), event() -> term())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current read model state for the projection."
  @spec current_state(GenServer.server()) :: term()
  def current_state(server), do: GenServer.call(server, :current_state)

  @doc "Returns the last-processed event version for the projection."
  @spec last_version(GenServer.server()) :: non_neg_integer()
  def last_version(server), do: GenServer.call(server, :last_version)

  @impl GenServer
  def init(opts) do
    stream_id = Keyword.fetch!(opts, :stream_id)
    projection_fn = Keyword.fetch!(opts, :projection_fn)
    initial_state = Keyword.get(opts, :initial_state, %{})
    projector_name = Keyword.fetch!(opts, :name)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 1_000)

    checkpoint = Checkpoint.load(projector_name) || 0

    state = %{
      stream_id: stream_id,
      projection_fn: projection_fn,
      model: initial_state,
      last_version: checkpoint,
      projector_name: projector_name,
      poll_interval: poll_interval
    }

    send(self(), :catchup)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:current_state, _from, state) do
    {:reply, state.model, state}
  end

  @impl GenServer
  def handle_call(:last_version, _from, state) do
    {:reply, state.last_version, state}
  end

  @impl GenServer
  def handle_info(:catchup, state) do
    new_state = process_new_events(state)
    schedule_catchup(state.poll_interval)
    {:noreply, new_state}
  end

  defp process_new_events(%{stream_id: stream_id, last_version: from_version} = state) do
    events = EventStore.read_stream(stream_id, from_version: from_version + 1, limit: 200)

    case events do
      [] ->
        state

      new_events ->
        updated_model = Enum.reduce(new_events, state.model, state.projection_fn)
        last = List.last(new_events).stream_version

        Checkpoint.save(state.projector_name, last)
        Logger.debug("[Projector] Applied #{length(new_events)} events", stream: stream_id, up_to: last)

        %{state | model: updated_model, last_version: last}
    end
  end

  defp schedule_catchup(interval), do: Process.send_after(self(), :catchup, interval)
end

defmodule Platform.ReadModelProjector.Checkpoint do
  @moduledoc "Persists and loads projector position checkpoints."

  alias Platform.Repo
  alias Platform.Projection.CheckpointRecord

  @spec load(atom()) :: non_neg_integer() | nil
  def load(projector_name) when is_atom(projector_name) do
    case Repo.get_by(CheckpointRecord, projector: Atom.to_string(projector_name)) do
      nil -> nil
      record -> record.last_version
    end
  end

  @spec save(atom(), non_neg_integer()) :: :ok
  def save(projector_name, version) when is_atom(projector_name) and is_integer(version) do
    name_str = Atom.to_string(projector_name)
    attrs = %{projector: name_str, last_version: version, updated_at: DateTime.utc_now()}
    Repo.insert!(%CheckpointRecord{} |> CheckpointRecord.changeset(attrs), on_conflict: {:replace, [:last_version, :updated_at]}, conflict_target: :projector)
    :ok
  end
end
```
