```elixir
defmodule PoolMonitor.Check do
  @moduledoc """
  The outcome of a single connection pool health check.
  """

  @enforce_keys [:pool_name, :status, :checked_at]
  defstruct [:pool_name, :status, :checked_at, :idle, :busy, :overflow, :queue_length, :message]

  @type status :: :healthy | :degraded | :saturated
  @type t :: %__MODULE__{
          pool_name: atom(),
          status: status(),
          checked_at: DateTime.t(),
          idle: non_neg_integer() | nil,
          busy: non_neg_integer() | nil,
          overflow: non_neg_integer() | nil,
          queue_length: non_neg_integer() | nil,
          message: String.t() | nil
        }
end

defmodule PoolMonitor.Inspector do
  @moduledoc """
  Inspects DBConnection pool status and classifies pool health.
  Thresholds are configurable per check to support different pool sizes.
  """

  alias PoolMonitor.Check

  @spec inspect_pool(atom(), keyword()) :: Check.t()
  def inspect_pool(pool_name, opts \\ []) when is_atom(pool_name) do
    saturated_threshold = Keyword.get(opts, :saturated_threshold, 0.9)
    degraded_threshold = Keyword.get(opts, :degraded_threshold, 0.7)

    case fetch_pool_stats(pool_name) do
      {:ok, stats} ->
        classify(pool_name, stats, saturated_threshold, degraded_threshold)

      {:error, reason} ->
        %Check{
          pool_name: pool_name,
          status: :saturated,
          checked_at: DateTime.utc_now(),
          message: "Failed to read pool stats: #{inspect(reason)}"
        }
    end
  end

  defp fetch_pool_stats(pool_name) do
    try do
      stats = DBConnection.status(pool_name)
      {:ok, stats}
    rescue
      err -> {:error, Exception.message(err)}
    end
  end

  defp classify(pool_name, stats, saturated_at, degraded_at) do
    idle = Map.get(stats, :idle, 0)
    busy = Map.get(stats, :busy, 0)
    overflow = Map.get(stats, :overflow, 0)
    queue = Map.get(stats, :queue_length, 0)
    total = idle + busy + overflow
    utilization = if total > 0, do: (busy + overflow) / total, else: 0.0

    {status, message} = determine_status(utilization, queue, saturated_at, degraded_at)

    %Check{
      pool_name: pool_name,
      status: status,
      checked_at: DateTime.utc_now(),
      idle: idle,
      busy: busy,
      overflow: overflow,
      queue_length: queue,
      message: message
    }
  end

  defp determine_status(utilization, queue, saturated_at, _degraded_at) when utilization >= saturated_at or queue > 5 do
    {:saturated, "Pool utilization #{Float.round(utilization * 100, 1)}% with #{queue} queued"}
  end

  defp determine_status(utilization, _queue, _saturated_at, degraded_at) when utilization >= degraded_at do
    {:degraded, "Pool utilization #{Float.round(utilization * 100, 1)}%"}
  end

  defp determine_status(_utilization, _queue, _saturated_at, _degraded_at) do
    {:healthy, nil}
  end
end

defmodule PoolMonitor.Watcher do
  @moduledoc """
  Periodically inspects all registered connection pools and emits the
  results via `:telemetry`. Alerts are broadcast when a pool transitions
  to `:saturated` status for the first time in a window.
  """

  use GenServer

  require Logger

  alias PoolMonitor.{Check, Inspector}

  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register_pool(atom(), keyword()) :: :ok
  def register_pool(pool_name, check_opts \\ []) when is_atom(pool_name) do
    GenServer.cast(__MODULE__, {:register, pool_name, check_opts})
  end

  @spec latest_checks() :: %{atom() => Check.t()}
  def latest_checks do
    GenServer.call(__MODULE__, :latest_checks)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    pools = Keyword.get(opts, :pools, []) |> Map.new(fn {name, o} -> {name, o} end)
    schedule_check(interval)
    {:ok, %{interval_ms: interval, pools: pools, latest: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, pool_name, check_opts}, state) do
    {:noreply, put_in(state, [:pools, pool_name], check_opts)}
  end

  @impl GenServer
  def handle_call(:latest_checks, _from, state) do
    {:reply, state.latest, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    new_latest =
      Map.new(state.pools, fn {pool_name, check_opts} ->
        check = Inspector.inspect_pool(pool_name, check_opts)
        emit_telemetry(check)
        maybe_alert(check, Map.get(state.latest, pool_name))
        {pool_name, check}
      end)

    schedule_check(state.interval_ms)
    {:noreply, %{state | latest: new_latest}}
  end

  defp emit_telemetry(%Check{} = check) do
    :telemetry.execute(
      [:pool_monitor, :check],
      %{idle: check.idle || 0, busy: check.busy || 0, queue_length: check.queue_length || 0},
      %{pool: check.pool_name, status: check.status}
    )
  end

  defp maybe_alert(%Check{status: :saturated}, %Check{status: prev}) when prev != :saturated do
    Logger.warning("Connection pool entered saturated state", pool: :pool_name)
  end

  defp maybe_alert(_current, _previous), do: :ok

  defp schedule_check(interval) do
    Process.send_after(self(), :check, interval)
  end
end
```
