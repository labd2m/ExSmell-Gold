```elixir
defmodule Infra.CircuitBreaker do
  @moduledoc """
  A circuit breaker that protects downstream services from cascading failures.
  Transitions between three states: `:closed` (normal operation),
  `:open` (blocking all calls), and `:half_open` (probing for recovery).
  """

  use GenServer

  require Logger

  @type cb_state :: :closed | :open | :half_open

  @type config :: %{
          failure_threshold: pos_integer(),
          reset_timeout_ms: pos_integer()
        }

  @type state :: %{
          name: atom(),
          cb_state: cb_state(),
          failure_count: non_neg_integer(),
          config: config(),
          opened_at_ms: integer() | nil
        }

  @spec start_link(atom(), config()) :: GenServer.on_start()
  def start_link(name, config) when is_atom(name) and is_map(config) do
    GenServer.start_link(__MODULE__, {name, config}, name: name)
  end

  @spec call(atom(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open} | {:error, :dependency_failure}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.call(name, {:execute, fun})
  end

  @spec status(atom()) :: cb_state()
  def status(name) when is_atom(name) do
    GenServer.call(name, :status)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(name, :reset)
  end

  @impl GenServer
  def init({name, config}) do
    {:ok, %{name: name, cb_state: :closed, failure_count: 0, config: config, opened_at_ms: nil}}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, state.cb_state, state}

  def handle_call({:execute, fun}, _from, %{cb_state: :open} = state) do
    if probe_window_elapsed?(state) do
      attempt_call(fun, %{state | cb_state: :half_open})
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:execute, fun}, _from, state) do
    attempt_call(fun, state)
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply, closed_state(state)}
  end

  defp attempt_call(fun, state) do
    case fun.() do
      {:ok, _} = success ->
        Logger.debug("Circuit breaker success", name: state.name, cb_state: state.cb_state)
        {:reply, success, closed_state(state)}

      {:error, _} ->
        updated = record_failure(state)
        Logger.warning("Circuit breaker failure", name: state.name, failures: updated.failure_count)
        {:reply, {:error, :dependency_failure}, updated}
    end
  end

  defp record_failure(%{failure_count: count, config: %{failure_threshold: threshold}} = state) do
    incremented = Map.update!(state, :failure_count, &(&1 + 1))
    if incremented.failure_count >= threshold, do: open_state(incremented), else: incremented
  end

  defp probe_window_elapsed?(%{opened_at_ms: ts, config: %{reset_timeout_ms: timeout}}) do
    System.monotonic_time(:millisecond) - ts >= timeout
  end

  defp open_state(state) do
    %{state | cb_state: :open, opened_at_ms: System.monotonic_time(:millisecond)}
  end

  defp closed_state(state) do
    %{state | cb_state: :closed, failure_count: 0, opened_at_ms: nil}
  end
end
```
