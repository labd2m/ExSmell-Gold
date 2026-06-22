```elixir
defmodule Platform.SnapshotStore do
  @moduledoc """
  A snapshot store for event-sourced aggregates.

  Periodic snapshots prevent unbounded event log growth by recording the
  full aggregate state at a known stream version. On load, the projector
  starts from the most recent snapshot and replays only newer events.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.{Repo, SnapshotStore.Snapshot}

  @type stream_id :: String.t()
  @type aggregate_type :: atom()
  @type version :: non_neg_integer()
  @type state :: term()

  @type snapshot_record :: %{
          stream_id: stream_id(),
          aggregate_type: aggregate_type(),
          version: version(),
          state: state(),
          taken_at: DateTime.t()
        }

  @doc """
  Saves a snapshot for `stream_id` at `version`.
  Overwrites any existing snapshot for the same stream.
  """
  @spec save(stream_id(), aggregate_type(), version(), state()) ::
          {:ok, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def save(stream_id, aggregate_type, version, state)
      when is_binary(stream_id) and is_atom(aggregate_type) and is_integer(version) do
    attrs = %{
      stream_id: stream_id,
      aggregate_type: Atom.to_string(aggregate_type),
      version: version,
      state: :erlang.term_to_binary(state) |> Base.encode64(),
      taken_at: DateTime.utc_now()
    }

    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:version, :state, :taken_at]},
      conflict_target: :stream_id
    )
  end

  @doc """
  Loads the most recent snapshot for `stream_id`.
  Returns `{:ok, snapshot}` or `{:error, :not_found}`.
  """
  @spec load(stream_id()) :: {:ok, snapshot_record()} | {:error, :not_found}
  def load(stream_id) when is_binary(stream_id) do
    case Repo.get_by(Snapshot, stream_id: stream_id) do
      nil -> {:error, :not_found}
      snapshot -> {:ok, deserialize(snapshot)}
    end
  end

  @doc """
  Returns `true` if a snapshot exists and the stream has grown by at least
  `threshold` events since the last snapshot was taken.
  """
  @spec snapshot_due?(stream_id(), version(), pos_integer()) :: boolean()
  def snapshot_due?(stream_id, current_version, threshold \\ 50)
      when is_integer(threshold) do
    case load(stream_id) do
      {:ok, %{version: snap_version}} -> current_version - snap_version >= threshold
      {:error, :not_found} -> current_version >= threshold
    end
  end

  @doc "Deletes the snapshot for `stream_id`. A no-op if none exists."
  @spec delete(stream_id()) :: :ok
  def delete(stream_id) when is_binary(stream_id) do
    from(s in Snapshot, where: s.stream_id == ^stream_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Cleans up snapshots for streams whose most recent event is older than
  `older_than_days`. Returns the count of removed snapshots.
  """
  @spec purge_stale(pos_integer()) :: non_neg_integer()
  def purge_stale(older_than_days) when is_integer(older_than_days) and older_than_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_days, :day)

    {count, _} =
      from(s in Snapshot, where: s.taken_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  defp deserialize(%Snapshot{} = snap) do
    state =
      snap.state
      |> Base.decode64!()
      |> :erlang.binary_to_term([:safe])

    %{
      stream_id: snap.stream_id,
      aggregate_type: String.to_existing_atom(snap.aggregate_type),
      version: snap.version,
      state: state,
      taken_at: snap.taken_at
    }
  end
end
```
