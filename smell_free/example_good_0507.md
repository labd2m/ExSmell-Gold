```elixir
defmodule MyApp.Infra.ConnectionPoolMonitor do
  @moduledoc """
  Monitors the Ecto database connection pool and emits structured
  telemetry events when pool utilisation crosses warning or critical
  thresholds. Designed to be attached once at application startup and
  driven entirely by `:telemetry` queue events from DBConnection.

  Attach via:

      MyApp.Infra.ConnectionPoolMonitor.attach()
  """

  require Logger

  @handler_id :connection_pool_monitor
  @warning_utilisation 0.75
  @critical_utilisation 0.90

  @type pool_stats :: %{
          pool_size: pos_integer(),
          checked_out: non_neg_integer(),
          utilisation: float()
        }

  @doc "Attaches the telemetry handler. Safe to call multiple times."
  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      @handler_id,
      [
        [:my_app, :repo, :query],
        [:db_connection, :checkout],
        [:db_connection, :checkin]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc "Detaches the telemetry handler."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event(list(), map(), map(), term()) :: :ok
  def handle_event([:db_connection, :checkout], _measurements, meta, _cfg) do
    stats = build_stats(meta)
    evaluate_and_emit(stats)
  end

  def handle_event(_event, _measurements, _meta, _cfg), do: :ok

  @doc """
  Returns current pool statistics by inspecting the DBConnection pool
  process. Returns `nil` when the pool is not running.
  """
  @spec current_stats() :: pool_stats() | nil
  def current_stats do
    case Process.whereis(MyApp.Repo.Pool) do
      nil ->
        nil

      pid ->
        info = :sys.get_state(pid)
        pool_size = Map.get(info, :pool_size, 10)
        checked_out = Map.get(info, :checked_out, 0)

        %{
          pool_size: pool_size,
          checked_out: checked_out,
          utilisation: if(pool_size > 0, do: checked_out / pool_size, else: 0.0)
        }
    end
  rescue
    _ -> nil
  end

  @spec build_stats(map()) :: pool_stats()
  defp build_stats(meta) do
    pool_size = Map.get(meta, :pool_size, 10)
    checked_out = Map.get(meta, :checked_out, 0)

    %{
      pool_size: pool_size,
      checked_out: checked_out,
      utilisation: if(pool_size > 0, do: checked_out / pool_size, else: 0.0)
    }
  end

  @spec evaluate_and_emit(pool_stats()) :: :ok
  defp evaluate_and_emit(stats) do
    cond do
      stats.utilisation >= @critical_utilisation ->
        Logger.error("db_pool_critical",
          utilisation_pct: round(stats.utilisation * 100),
          checked_out: stats.checked_out,
          pool_size: stats.pool_size
        )

        :telemetry.execute(
          [:my_app, :db_pool, :threshold_exceeded],
          %{utilisation: stats.utilisation},
          %{severity: :critical}
        )

      stats.utilisation >= @warning_utilisation ->
        Logger.warning("db_pool_warning",
          utilisation_pct: round(stats.utilisation * 100),
          checked_out: stats.checked_out,
          pool_size: stats.pool_size
        )

        :telemetry.execute(
          [:my_app, :db_pool, :threshold_exceeded],
          %{utilisation: stats.utilisation},
          %{severity: :warning}
        )

      true ->
        :ok
    end
  end
end
```
