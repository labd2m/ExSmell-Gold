```elixir
defmodule CircuitBreaker do
  use GenServer

  @moduledoc """
  Implements the circuit-breaker pattern for a named external dependency.
  Tracks consecutive failures, opens the circuit after a threshold,
  and probes for recovery via half-open state.
  """

  @default_failure_threshold 5
  @default_success_threshold 2
  @default_timeout_ms 60_000
  @default_half_open_probe_interval_ms 10_000

  defstruct [
    :name,
    :state,
    :failure_threshold,
    :success_threshold,
    :timeout_ms,
    :opened_at,
    consecutive_failures: 0,
    consecutive_successes: 0,
    total_calls: 0,
    total_failures: 0,
    total_successes: 0
  ]

  def start(name, opts \\ []) do
    config = %{
      name: name,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }

    GenServer.start(__MODULE__, config, name: via(name))
  end

  def call(name, fun) do
    GenServer.call(via(name), {:call, fun})
  end

  def trip(name) do
    GenServer.cast(via(name), :trip)
  end

  def reset(name) do
    GenServer.cast(via(name), :reset)
  end

  def status(name) do
    GenServer.call(via(name), :status)
  end

  defp via(name), do: {:via, Registry, {CircuitBreakerRegistry, name}}

  ## Callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      name: config.name,
      state: :closed,
      failure_threshold: config.failure_threshold,
      success_threshold: config.success_threshold,
      timeout_ms: config.timeout_ms
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:call, _fun}, _from, %{state: :open} = cb_state) do
    if should_attempt_reset?(cb_state) do
      {:reply, {:error, :circuit_open}, %{cb_state | state: :half_open}}
    else
      {:reply, {:error, :circuit_open}, cb_state}
    end
  end

  def handle_call({:call, fun}, _from, cb_state) do
    result =
      try do
        {:ok, fun.()}
      rescue
        error -> {:error, error}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    new_state = record_result(result, cb_state)
    {:reply, result, new_state}
  end

  def handle_call(:status, _from, cb_state) do
    status = %{
      name: cb_state.name,
      circuit: cb_state.state,
      consecutive_failures: cb_state.consecutive_failures,
      total_calls: cb_state.total_calls,
      total_failures: cb_state.total_failures,
      total_successes: cb_state.total_successes,
      opened_at: cb_state.opened_at,
      failure_rate: failure_rate(cb_state)
    }

    {:reply, status, cb_state}
  end

  @impl true
  def handle_cast(:trip, cb_state) do
    {:noreply, open_circuit(cb_state)}
  end

  def handle_cast(:reset, cb_state) do
    {:noreply, %{cb_state | state: :closed, consecutive_failures: 0, consecutive_successes: 0, opened_at: nil}}
  end

  @impl true
  def handle_info(:attempt_half_open, %{state: :open} = cb_state) do
    {:noreply, %{cb_state | state: :half_open}}
  end

  def handle_info(:attempt_half_open, cb_state), do: {:noreply, cb_state}

  defp record_result({:ok, _}, %{state: :half_open} = cb_state) do
    successes = cb_state.consecutive_successes + 1

    if successes >= cb_state.success_threshold do
      %{cb_state | state: :closed, consecutive_failures: 0, consecutive_successes: 0,
        total_calls: cb_state.total_calls + 1, total_successes: cb_state.total_successes + 1}
    else
      %{cb_state | consecutive_successes: successes,
        total_calls: cb_state.total_calls + 1, total_successes: cb_state.total_successes + 1}
    end
  end

  defp record_result({:ok, _}, cb_state) do
    %{cb_state | consecutive_failures: 0,
      total_calls: cb_state.total_calls + 1,
      total_successes: cb_state.total_successes + 1}
  end

  defp record_result({:error, _}, cb_state) do
    failures = cb_state.consecutive_failures + 1
    updated = %{cb_state | consecutive_failures: failures,
      total_calls: cb_state.total_calls + 1,
      total_failures: cb_state.total_failures + 1}

    if failures >= cb_state.failure_threshold, do: open_circuit(updated), else: updated
  end

  defp open_circuit(cb_state) do
    Process.send_after(self(), :attempt_half_open, @default_half_open_probe_interval_ms)
    %{cb_state | state: :open, opened_at: DateTime.utc_now(), consecutive_successes: 0}
  end

  defp should_attempt_reset?(%{opened_at: nil}), do: false
  defp should_attempt_reset?(cb_state) do
    elapsed = DateTime.diff(DateTime.utc_now(), cb_state.opened_at, :millisecond)
    elapsed >= cb_state.timeout_ms
  end

  defp failure_rate(%{total_calls: 0}), do: 0.0
  defp failure_rate(%{total_calls: tc, total_failures: tf}), do: tf / tc
end

defmodule ExternalServiceProxy do
  @moduledoc "Wraps external HTTP/RPC calls behind a named circuit breaker."

  def call(service_name, fun, opts \\ []) do
    ensure_breaker(service_name, opts)

    CircuitBreaker.call(service_name, fun)
  end

  defp ensure_breaker(service_name, opts) do
    case CircuitBreaker.start(service_name, opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
```
