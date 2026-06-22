```elixir
defmodule EventSourcing.ReplayService do
  @moduledoc """
  Rebuilds read models by replaying all domain events from the event store.
  Replay can be scoped to a specific aggregate type, a time range, or a
  single aggregate ID. Progress is tracked in ETS and broadcast via PubSub
  so admin tooling can display live replay status without polling the database.
  The replay runs in a supervised Task so it does not block the caller and
  can be monitored and cancelled independently.
  """

  alias EventSourcing.{EventStore, ProjectionRegistry}

  require Logger

  @pubsub_topic "replay:progress"
  @table :replay_status

  @type replay_id :: binary()
  @type replay_opts :: [
          aggregate_type: binary() | nil,
          aggregate_id: binary() | nil,
          from_position: non_neg_integer(),
          to_position: non_neg_integer() | nil,
          batch_size: pos_integer(),
          projections: [module()]
        ]

  @doc """
  Starts a supervised replay run with the given options. Returns `{:ok, replay_id}`
  immediately; progress is observable via `status/1` and PubSub broadcasts.
  """
  @spec start(replay_opts()) :: {:ok, replay_id()}
  def start(opts \\ []) do
    replay_id = generate_replay_id()
    init_status(replay_id, opts)

    Task.Supervisor.start_child(
      EventSourcing.ReplaySupervisor,
      fn -> run_replay(replay_id, opts) end,
      restart: :temporary
    )

    Logger.info("Replay started", replay_id: replay_id, opts: redact_opts(opts))
    {:ok, replay_id}
  end

  @doc """
  Returns the current status of a replay run, or `{:error, :not_found}`.
  """
  @spec status(replay_id()) :: {:ok, map()} | {:error, :not_found}
  def status(replay_id) when is_binary(replay_id) do
    ensure_table()

    case :ets.lookup(@table, replay_id) do
      [{^replay_id, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private implementation
  # ---------------------------------------------------------------------------

  defp run_replay(replay_id, opts) do
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    projections = Keyword.get(opts, :projections, ProjectionRegistry.all())

    stream_opts = build_stream_opts(opts)
    total = EventStore.count(stream_opts)

    update_status(replay_id, %{state: :running, total: total, processed: 0, failed: 0})
    broadcast_progress(replay_id, :started, %{total: total})

    {processed, failed} =
      stream_opts
      |> EventStore.stream(batch_size: batch_size)
      |> Enum.reduce({0, 0}, fn event, {ok, err} ->
        case apply_to_projections(event, projections) do
          :ok ->
            new_ok = ok + 1

            if rem(new_ok, batch_size) == 0 do
              update_status(replay_id, %{processed: new_ok, failed: err})
              broadcast_progress(replay_id, :progress, %{processed: new_ok, total: total})
            end

            {new_ok, err}

          {:error, reason} ->
            Logger.warning("Event replay failed",
              replay_id: replay_id,
              event_id: event.id,
              reason: inspect(reason)
            )

            {ok, err + 1}
        end
      end)

    final_state = if failed == 0, do: :completed, else: :completed_with_errors
    update_status(replay_id, %{state: final_state, processed: processed, failed: failed})
    broadcast_progress(replay_id, :finished, %{processed: processed, failed: failed, total: total})

    Logger.info("Replay finished",
      replay_id: replay_id,
      processed: processed,
      failed: failed
    )
  rescue
    e ->
      error_msg = Exception.message(e)
      update_status(replay_id, %{state: :failed, error: error_msg})
      broadcast_progress(replay_id, :failed, %{error: error_msg})
      Logger.error("Replay crashed", replay_id: replay_id, error: error_msg)
  end

  defp apply_to_projections(event, projections) do
    Enum.reduce_while(projections, :ok, fn projection, :ok ->
      case projection.handle(event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_stream_opts(opts) do
    opts
    |> Keyword.take([:aggregate_type, :aggregate_id, :from_position, :to_position])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp init_status(replay_id, opts) do
    ensure_table()

    status = %{
      replay_id: replay_id,
      state: :starting,
      total: nil,
      processed: 0,
      failed: 0,
      started_at: DateTime.utc_now(),
      opts: redact_opts(opts)
    }

    :ets.insert(@table, {replay_id, status})
  end

  defp update_status(replay_id, updates) do
    case :ets.lookup(@table, replay_id) do
      [{^replay_id, current}] ->
        :ets.insert(@table, {replay_id, Map.merge(current, updates)})

      [] ->
        :ok
    end
  end

  defp broadcast_progress(replay_id, event, payload) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @pubsub_topic, {event, replay_id, payload})
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public])
    end
  end

  defp generate_replay_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp redact_opts(opts) do
    Keyword.take(opts, [:aggregate_type, :aggregate_id, :from_position, :to_position, :batch_size])
  end
end
```
