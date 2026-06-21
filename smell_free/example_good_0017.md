# File: `example_good_17.md`

```elixir
defmodule Payments.CircuitBreaker do
  @moduledoc """
  GenServer implementing a circuit breaker pattern for external payment
  gateway calls.

  The breaker moves through three states:
  - `:closed` — requests pass through normally
  - `:open` — requests are rejected immediately without contacting the gateway
  - `:half_open` — a single probe request is permitted to test recovery

  State transitions are driven by configurable failure thresholds and
  a recovery timeout.
  """

  use GenServer

  require Logger

  @default_failure_threshold 5
  @default_recovery_timeout_ms 30_000
  @default_sample_window_ms 60_000

  @type circuit_state :: :closed | :open | :half_open
  @type opts :: [
          failure_threshold: pos_integer(),
          recovery_timeout_ms: pos_integer(),
          sample_window_ms: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes `fun/0` through the circuit breaker.

  When the circuit is closed or half-open, invokes `fun/0` and records
  success or failure. When open, immediately returns `{:error, :circuit_open}`
  without calling `fun/0`.
  """
  @spec call((-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open | term()}
  def call(fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:run, fun})
  end

  @doc """
  Returns the current circuit state and failure counters.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Manually resets the circuit breaker to the closed state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       state: :closed,
       failure_count: 0,
       last_failure_at: nil,
       failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
       recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, @default_recovery_timeout_ms),
       sample_window_ms: Keyword.get(opts, :sample_window_ms, @default_sample_window_ms)
     }}
  end

  @impl GenServer
  def handle_call({:run, fun}, _from, %{state: :open} = state) do
    if recovery_elapsed?(state) do
      {:reply, attempt_probe(fun), transition_to_half_open(state)}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  @impl GenServer
  def handle_call({:run, fun}, _from, %{state: circuit_state} = state)
      when circuit_state in [:closed, :half_open] do
    case fun.() do
      {:ok, result} ->
        {:reply, {:ok, result}, on_success(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, on_failure(state)}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    info = Map.take(state, [:state, :failure_count, :last_failure_at])
    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    Logger.info("Circuit breaker manually reset to :closed")
    {:noreply, reset_state(state)}
  end

  defp attempt_probe(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp on_success(%{state: :half_open} = state) do
    Logger.info("Circuit breaker recovered, transitioning to :closed")
    reset_state(state)
  end

  defp on_success(state), do: %{state | failure_count: 0}

  defp on_failure(%{failure_count: count, failure_threshold: threshold} = state)
       when count + 1 >= threshold do
    Logger.warning("Circuit breaker opening after #{count + 1} failures")
    %{state | state: :open, failure_count: count + 1, last_failure_at: System.monotonic_time(:millisecond)}
  end

  defp on_failure(state) do
    %{state | failure_count: state.failure_count + 1}
  end

  defp recovery_elapsed?(%{last_failure_at: nil}), do: false

  defp recovery_elapsed?(%{last_failure_at: ts, recovery_timeout_ms: timeout}) do
    System.monotonic_time(:millisecond) - ts >= timeout
  end

  defp transition_to_half_open(state), do: %{state | state: :half_open}

  defp reset_state(state) do
    %{state | state: :closed, failure_count: 0, last_failure_at: nil}
  end
end
```
