```elixir
defmodule EventSourcing.Aggregate do
  @moduledoc """
  Behaviour for event-sourced domain aggregates.

  Implementing modules declare the initial (empty) state and handle each
  event type in `apply_event/2`. Snapshots are optional; implementing
  `snapshot_version/1` enables the loader to skip replaying older events.
  """

  @callback initial_state() :: struct()
  @callback apply_event(state :: struct(), event :: map()) :: struct()
  @callback aggregate_id(state :: struct()) :: String.t()
end

defmodule EventSourcing.Snapshot do
  @moduledoc false

  @type t :: %__MODULE__{
          aggregate_id: String.t(),
          state: struct(),
          version: non_neg_integer(),
          taken_at: DateTime.t()
        }

  defstruct [:aggregate_id, :state, :version, :taken_at]
end

defmodule EventSourcing.Loader do
  @moduledoc """
  Reconstructs an aggregate's current state by replaying its event stream,
  optionally starting from a saved snapshot to reduce replay cost.

  The loader fetches the latest snapshot for the aggregate (when available)
  and then replays only events that occurred after the snapshot version.
  Snapshots are taken automatically after the event count exceeds a
  configurable threshold.
  """

  alias EventSourcing.{Aggregate, Snapshot}

  @type opts :: [
          event_store: module(),
          snapshot_store: module(),
          snapshot_threshold: pos_integer()
        ]

  @spec load(String.t(), module(), opts()) ::
          {:ok, struct()} | {:error, :aggregate_not_found | term()}
  def load(aggregate_id, aggregate_module, opts) when is_binary(aggregate_id) do
    event_store = Keyword.fetch!(opts, :event_store)
    snapshot_store = Keyword.get(opts, :snapshot_store)
    threshold = Keyword.get(opts, :snapshot_threshold, 100)

    {base_state, from_version} = load_snapshot(aggregate_id, aggregate_module, snapshot_store)

    case event_store.fetch_from(aggregate_id, from_version) do
      {:ok, []} when from_version == 0 ->
        {:error, :aggregate_not_found}

      {:ok, events} ->
        state = Enum.reduce(events, base_state, &aggregate_module.apply_event(&2, &1))

        if length(events) >= threshold and snapshot_store do
          take_snapshot(state, aggregate_module, from_version + length(events), snapshot_store)
        end

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec rebuild(String.t(), module(), opts()) :: {:ok, struct()} | {:error, term()}
  def rebuild(aggregate_id, aggregate_module, opts) do
    event_store = Keyword.fetch!(opts, :event_store)

    case event_store.fetch_from(aggregate_id, 0) do
      {:ok, []} -> {:error, :aggregate_not_found}
      {:ok, events} ->
        state = Enum.reduce(events, aggregate_module.initial_state(), &aggregate_module.apply_event(&2, &1))
        {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_snapshot(_id, aggregate_module, nil) do
    {aggregate_module.initial_state(), 0}
  end

  defp load_snapshot(aggregate_id, aggregate_module, snapshot_store) do
    case snapshot_store.latest(aggregate_id) do
      {:ok, %Snapshot{state: state, version: version}} -> {state, version}
      {:error, _} -> {aggregate_module.initial_state(), 0}
    end
  end

  defp take_snapshot(state, aggregate_module, version, snapshot_store) do
    snapshot = %Snapshot{
      aggregate_id: aggregate_module.aggregate_id(state),
      state: state,
      version: version,
      taken_at: DateTime.utc_now()
    }

    snapshot_store.save(snapshot)
  end
end
```
