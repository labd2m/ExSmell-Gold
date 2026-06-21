```elixir
defmodule MyApp.Observability.HealthChecker do
  @moduledoc """
  Aggregates liveness and readiness probes from registered subsystem
  checks and exposes the results via a single `check/1` call. Health
  checks are plain zero-arity functions registered at startup; each is
  executed in a supervised Task with a per-check timeout so that a slow
  or hanging dependency never blocks the HTTP health endpoint.

  Liveness indicates the process is alive. Readiness indicates the
  application can serve traffic (database reachable, caches warm, etc.).
  """

  use GenServer

  require Logger

  @default_timeout_ms 3_000

  @type check_name :: atom()
  @type check_fn :: (-> :ok | {:error, term()})
  @type probe :: :liveness | :readiness
  @type check_result :: %{name: check_name(), status: :ok | :error, detail: term()}
  @type health_result :: %{status: :ok | :degraded, checks: [check_result()]}

  @doc "Starts the health checker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers `fun` as a health check for the given `probe` type."
  @spec register(probe(), check_name(), check_fn()) :: :ok
  def register(probe, name, fun)
      when probe in [:liveness, :readiness] and is_atom(name) and is_function(fun, 0) do
    GenServer.call(__MODULE__, {:register, probe, name, fun})
  end

  @doc """
  Runs all checks for `probe` concurrently and returns an aggregated
  health result. Overall status is `:ok` only when every check passes.
  """
  @spec check(probe()) :: health_result()
  def check(probe) when probe in [:liveness, :readiness] do
    GenServer.call(__MODULE__, {:check, probe}, 10_000)
  end

  @impl GenServer
  def init(opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    {:ok, %{checks: %{liveness: [], readiness: []}, timeout_ms: timeout}}
  end

  @impl GenServer
  def handle_call({:register, probe, name, fun}, _from, state) do
    entry = {name, fun}
    updated = Map.update!(state.checks, probe, &[entry | &1])
    {:reply, :ok, %{state | checks: updated}}
  end

  @impl GenServer
  def handle_call({:check, probe}, _from, state) do
    results = run_checks(Map.get(state.checks, probe, []), state.timeout_ms)
    overall = if Enum.all?(results, &(&1.status == :ok)), do: :ok, else: :degraded
    {:reply, %{status: overall, checks: results}, state}
  end

  @spec run_checks([{check_name(), check_fn()}], pos_integer()) :: [check_result()]
  defp run_checks(checks, timeout_ms) do
    checks
    |> Task.async_stream(
      fn {name, fun} -> {name, execute_check(fun)} end,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, {name, :ok}} ->
        %{name: name, status: :ok, detail: nil}

      {:ok, {name, {:error, reason}}} ->
        Logger.warning("health_check_failed", check: name, reason: inspect(reason))
        %{name: name, status: :error, detail: inspect(reason)}

      {:exit, reason} ->
        Logger.warning("health_check_timeout", reason: inspect(reason))
        %{name: :unknown, status: :error, detail: :timeout}
    end)
  end

  @spec execute_check(check_fn()) :: :ok | {:error, term()}
  defp execute_check(fun) do
    fun.()
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
```
