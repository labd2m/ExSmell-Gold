```elixir
defmodule Resilience.CircuitBreaker do
  @moduledoc """
  A half-open/open/closed circuit breaker for protecting downstream service calls.

  The breaker begins in the `:closed` state. After `failure_threshold`
  consecutive failures it transitions to `:open`, rejecting all calls with
  `{:error, :circuit_open}` until a recovery window elapses. At that point
  it enters `:half_open`, allowing a single probe request to pass through.
  A successful probe resets the breaker to `:closed`; a failed probe
  re-opens it and restarts the recovery timer.
  """

  use GenServer

  @type circuit_state :: :closed | :open | :half_open

  @type opts :: [
          name: atom(),
          failure_threshold: pos_integer(),
          recovery_window_ms: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call(atom(), (-> term())) ::
          {:ok, term()} | {:error, :circuit_open} | {:error, term()}
  def call(name, func) when is_atom(name) and is_function(func, 0) do
    GenServer.call(name, {:call, func})
  end

  @spec circuit_state(atom()) :: circuit_state()
  def circuit_state(name) when is_atom(name) do
    GenServer.call(name, :circuit_state)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(name, :reset)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       circuit: :closed,
       failures: 0,
       failure_threshold: Keyword.get(opts, :failure_threshold, 5),
       recovery_window_ms: Keyword.get(opts, :recovery_window_ms, 30_000)
     }}
  end

  @impl GenServer
  def handle_call({:call, _func}, _from, %{circuit: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:call, func}, _from, state) do
    case execute_safely(func) do
      {:ok, result} ->
        {:reply, {:ok, result}, closed_state(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, record_failure(state)}
    end
  end

  def handle_call(:circuit_state, _from, state) do
    {:reply, state.circuit, state}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply, closed_state(state)}
  end

  @impl GenServer
  def handle_info(:attempt_recovery, state) do
    {:noreply, %{state | circuit: :half_open}}
  end

  defp execute_safely(func) do
    {:ok, func.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp record_failure(%{failures: f, failure_threshold: threshold} = state)
       when f + 1 >= threshold do
    Process.send_after(self(), :attempt_recovery, state.recovery_window_ms)
    %{state | failures: 0, circuit: :open}
  end

  defp record_failure(state), do: %{state | failures: state.failures + 1}

  defp closed_state(state), do: %{state | failures: 0, circuit: :closed}
end
```
