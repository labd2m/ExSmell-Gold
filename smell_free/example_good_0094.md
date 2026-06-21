# File: `example_good_94.md`

```elixir
defmodule Health.AggregateChecker do
  @moduledoc """
  Aggregates the results of registered health checks and exposes a
  consolidated status endpoint for load balancer and monitoring probes.

  Each health check is a named function with a configurable timeout.
  Checks run concurrently via supervised Tasks and are never allowed to
  block the caller beyond the configured deadline.
  """

  use GenServer

  require Logger

  @default_check_timeout_ms 5_000
  @default_refresh_interval_ms 30_000

  @type check_name :: atom()
  @type check_fn :: (-> :ok | {:error, term()})
  @type status :: :healthy | :degraded | :unhealthy

  @type check_definition :: %{
          name: check_name(),
          run: check_fn(),
          timeout_ms: pos_integer(),
          critical: boolean()
        }

  @type check_result :: %{
          name: check_name(),
          status: :ok | :error | :timeout,
          detail: term(),
          duration_ms: non_neg_integer()
        }

  @type aggregate_result :: %{
          status: status(),
          checks: [check_result()],
          evaluated_at: DateTime.t()
        }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a health check function under a unique name.

  Options:
  - `:timeout_ms` — maximum time allowed for a single check (default: 5000)
  - `:critical` — when `true`, a failing check marks the system `:unhealthy`
    rather than `:degraded` (default: true)
  """
  @spec register(check_name(), check_fn(), keyword()) :: :ok
  def register(name, run_fn, opts \\ [])
      when is_atom(name) and is_function(run_fn, 0) do
    GenServer.cast(__MODULE__, {:register, name, run_fn, opts})
  end

  @doc """
  Runs all registered health checks synchronously and returns the
  aggregate result.
  """
  @spec run_checks() :: aggregate_result()
  def run_checks do
    GenServer.call(__MODULE__, :run_checks, 60_000)
  end

  @doc """
  Returns the cached result from the most recent automatic refresh,
  or runs checks immediately if no cached result exists.
  """
  @spec status() :: aggregate_result()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl GenServer
  def init(opts) do
    refresh_interval_ms = Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)
    schedule_refresh(refresh_interval_ms)

    {:ok, %{checks: [], cached_result: nil, refresh_interval_ms: refresh_interval_ms}}
  end

  @impl GenServer
  def handle_cast({:register, name, run_fn, opts}, state) do
    definition = %{
      name: name,
      run: run_fn,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_check_timeout_ms),
      critical: Keyword.get(opts, :critical, true)
    }

    updated = Enum.reject(state.checks, &(&1.name == name))
    {:noreply, %{state | checks: [definition | updated]}}
  end

  @impl GenServer
  def handle_call(:run_checks, _from, state) do
    result = execute_all_checks(state.checks)
    {:reply, result, %{state | cached_result: result}}
  end

  @impl GenServer
  def handle_call(:status, _from, %{cached_result: nil} = state) do
    result = execute_all_checks(state.checks)
    {:reply, result, %{state | cached_result: result}}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.cached_result, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    result = execute_all_checks(state.checks)
    schedule_refresh(state.refresh_interval_ms)
    {:noreply, %{state | cached_result: result}}
  end

  defp execute_all_checks(checks) do
    results =
      checks
      |> Enum.map(&run_check_with_timeout/1)

    %{
      status: derive_status(checks, results),
      checks: results,
      evaluated_at: DateTime.utc_now()
    }
  end

  defp run_check_with_timeout(%{name: name, run: run_fn, timeout_ms: timeout}) do
    start_ms = System.monotonic_time(:millisecond)
    task = Task.async(fn -> run_fn.() end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        %{name: name, status: :ok, detail: nil, duration_ms: elapsed(start_ms)}

      {:ok, {:error, reason}} ->
        %{name: name, status: :error, detail: reason, duration_ms: elapsed(start_ms)}

      nil ->
        %{name: name, status: :timeout, detail: :timeout, duration_ms: timeout}
    end
  end

  defp derive_status(definitions, results) do
    critical_names =
      definitions
      |> Enum.filter(& &1.critical)
      |> MapSet.new(& &1.name)

    has_critical_failure =
      Enum.any?(results, fn r ->
        r.status != :ok and MapSet.member?(critical_names, r.name)
      end)

    has_any_failure = Enum.any?(results, &(&1.status != :ok))

    cond do
      has_critical_failure -> :unhealthy
      has_any_failure -> :degraded
      true -> :healthy
    end
  end

  defp elapsed(start_ms), do: System.monotonic_time(:millisecond) - start_ms
  defp schedule_refresh(interval_ms), do: Process.send_after(self(), :refresh, interval_ms)
end
```
