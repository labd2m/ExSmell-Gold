```elixir
defmodule Database.PoolMonitor do
  @moduledoc """
  A supervised GenServer that periodically samples DBConnection pool
  telemetry, emits health metrics, and triggers alerts when the pool
  saturation crosses configurable warning and critical thresholds.
  """

  use GenServer

  alias Database.{AlertDispatcher, MetricsRecorder}

  @sample_interval_ms 10_000

  @type pool_stats :: %{
          checked_out: non_neg_integer(),
          available: non_neg_integer(),
          queue_depth: non_neg_integer(),
          total: pos_integer()
        }

  @type thresholds :: %{warn_pct: float(), critical_pct: float()}

  @default_thresholds %{warn_pct: 0.75, critical_pct: 0.90}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current_stats() :: {:ok, pool_stats()} | {:error, :unavailable}
  def current_stats do
    GenServer.call(__MODULE__, :current_stats)
  end

  @spec saturation() :: {:ok, float()} | {:error, :unavailable}
  def saturation do
    case current_stats() do
      {:ok, stats} -> {:ok, stats.checked_out / stats.total}
      err -> err
    end
  end

  @impl GenServer
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    thresholds = Keyword.get(opts, :thresholds, @default_thresholds)
    schedule_sample()
    {:ok, %{repo: repo, thresholds: thresholds, last_stats: nil}}
  end

  @impl GenServer
  def handle_call(:current_stats, _from, %{last_stats: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(:current_stats, _from, state) do
    {:reply, {:ok, state.last_stats}, state}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    new_stats = collect_stats(state.repo)
    emit_metrics(new_stats)
    check_thresholds(new_stats, state.thresholds)
    schedule_sample()
    {:noreply, %{state | last_stats: new_stats}}
  end

  @spec collect_stats(module()) :: pool_stats()
  defp collect_stats(repo) do
    pool = repo.config()[:pool_size] || 10

    {checked_out, queue_depth} =
      :telemetry.execute([:db_connection, :pool, :checkout], %{}, %{})
      |> case do
        _ -> sample_via_ets(repo)
      end

    %{
      checked_out: checked_out,
      available: max(0, pool - checked_out),
      queue_depth: queue_depth,
      total: pool
    }
  end

  @spec sample_via_ets(module()) :: {non_neg_integer(), non_neg_integer()}
  defp sample_via_ets(repo) do
    pool_pid = Process.whereis(repo)

    case pool_pid do
      nil -> {0, 0}
      pid ->
        info = Process.info(pid, [:message_queue_len]) || []
        queue = Keyword.get(info, :message_queue_len, 0)
        {0, queue}
    end
  end

  @spec emit_metrics(pool_stats()) :: :ok
  defp emit_metrics(stats) do
    saturation = stats.checked_out / stats.total
    MetricsRecorder.gauge("db.pool.checked_out", stats.checked_out)
    MetricsRecorder.gauge("db.pool.available", stats.available)
    MetricsRecorder.gauge("db.pool.saturation", saturation)
    MetricsRecorder.gauge("db.pool.queue_depth", stats.queue_depth)
    :ok
  end

  @spec check_thresholds(pool_stats(), thresholds()) :: :ok
  defp check_thresholds(stats, thresholds) do
    saturation = stats.checked_out / stats.total

    cond do
      saturation >= thresholds.critical_pct ->
        AlertDispatcher.fire(:critical, "DB pool critical: #{Float.round(saturation * 100, 1)}% saturated")

      saturation >= thresholds.warn_pct ->
        AlertDispatcher.fire(:warn, "DB pool warning: #{Float.round(saturation * 100, 1)}% saturated")

      true ->
        :ok
    end
  end

  @spec schedule_sample() :: reference()
  defp schedule_sample, do: Process.send_after(self(), :sample, @sample_interval_ms)
end
```
