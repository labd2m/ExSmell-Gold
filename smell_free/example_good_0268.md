```elixir
defmodule Infrastructure.CircuitBreaker do
  @moduledoc """
  A supervised GenServer implementing the circuit-breaker pattern for
  outbound HTTP integrations. The breaker cycles through `:closed`,
  `:open`, and `:half_open` states to prevent cascading failures when
  a downstream service becomes unavailable. Each named breaker instance
  is identified by a unique atom and managed via a `Registry`.
  """

  use GenServer

  require Logger

  @type breaker_name :: atom()
  @type breaker_opts :: [
          failure_threshold: pos_integer(),
          recovery_timeout_ms: pos_integer(),
          probe_timeout_ms: pos_integer()
        ]

  @default_threshold 5
  @default_recovery_ms 30_000
  @default_probe_ms 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(breaker_name(), breaker_opts()) :: GenServer.on_start()
  def start_link(name, opts \\ []) when is_atom(name) do
    GenServer.start_link(__MODULE__, {name, opts},
      name: via(name)
    )
  end

  @doc """
  Attempts to execute `fun` through the named circuit breaker.
  Returns `{:ok, result}`, `{:error, result}`, or `{:error, :circuit_open}`.
  """
  @spec call(breaker_name(), (() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()} | {:error, :circuit_open}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.call(via(name), {:call, fun})
  end

  @doc """
  Returns the current breaker state map for monitoring or diagnostics.
  """
  @spec state(breaker_name()) :: map()
  def state(name) when is_atom(name) do
    GenServer.call(via(name), :state)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init({name, opts}) do
    {:ok,
     %{
       name: name,
       status: :closed,
       failure_count: 0,
       failure_threshold: Keyword.get(opts, :failure_threshold, @default_threshold),
       recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, @default_recovery_ms),
       probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, @default_probe_ms),
       opened_at: nil
     }}
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    {:reply, Map.take(state, [:status, :failure_count, :opened_at]), state}
  end

  def handle_call({:call, fun}, _from, %{status: :open} = state) do
    if recovered?(state) do
      try_probe(fun, state)
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:call, fun}, _from, state) do
    result = fun.()
    {:reply, result, update_on_result(result, state)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp try_probe(fun, state) do
    half_open = %{state | status: :half_open}

    case fun.() do
      {:ok, _} = ok ->
        Logger.info("CircuitBreaker #{state.name}: recovered, closing circuit")
        {:reply, ok, reset(half_open)}

      {:error, _} = err ->
        Logger.warning("CircuitBreaker #{state.name}: probe failed, reopening circuit")
        {:reply, err, open(half_open)}
    end
  end

  defp update_on_result({:ok, _}, state), do: reset(state)

  defp update_on_result({:error, reason}, %{failure_count: count, failure_threshold: threshold} = state) do
    new_count = count + 1

    if new_count >= threshold do
      Logger.warning("CircuitBreaker #{state.name}: threshold reached, opening circuit",
        reason: inspect(reason)
      )
      open(%{state | failure_count: new_count})
    else
      %{state | failure_count: new_count}
    end
  end

  defp open(state), do: %{state | status: :open, opened_at: System.monotonic_time(:millisecond)}
  defp reset(state), do: %{state | status: :closed, failure_count: 0, opened_at: nil}

  defp recovered?(%{opened_at: opened_at, recovery_timeout_ms: timeout}) do
    System.monotonic_time(:millisecond) - opened_at >= timeout
  end

  defp via(name), do: {:via, Registry, {Infrastructure.CircuitBreakerRegistry, name}}
end
```
