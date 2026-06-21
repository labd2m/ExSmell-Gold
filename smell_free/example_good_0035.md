```elixir
defmodule Resilience.CircuitBreaker do
  @moduledoc """
  A GenServer-based circuit breaker that protects downstream dependencies
  from cascading failures.

  The circuit cycles through three states: `:closed` (calls pass through),
  `:open` (calls are rejected immediately), and `:half_open` (a probe call
  is allowed to test recovery). Transition thresholds are configurable.
  """

  use GenServer

  require Logger

  @type circuit :: :closed | :open | :half_open
  @type config :: %{
          failure_threshold: pos_integer(),
          success_threshold: pos_integer(),
          reset_timeout_ms: pos_integer()
        }
  @type state :: %{
          circuit: circuit(),
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          config: config()
        }
  @type call_result :: {:ok, term()} | {:error, :circuit_open | term()}

  @default_config %{failure_threshold: 5, success_threshold: 2, reset_timeout_ms: 30_000}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes `fun` if the circuit is closed or half-open, tracking outcomes.
  Returns `{:error, :circuit_open}` without invoking `fun` when the circuit is open.
  """
  @spec call(GenServer.server(), (-> term())) :: call_result()
  def call(server, fun) when is_function(fun, 0) do
    GenServer.call(server, {:execute, fun})
  end

  @doc "Returns the current circuit state and counters."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    config = Map.merge(@default_config, Keyword.get(opts, :config, %{}))
    {:ok, %{circuit: :closed, failures: 0, successes: 0, config: config}}
  end

  @impl GenServer
  def handle_call({:execute, _fun}, _from, %{circuit: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:execute, fun}, _from, state) do
    result = safe_invoke(fun)
    {:reply, result, transition(state, result)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:circuit, :failures, :successes]), state}
  end

  @impl GenServer
  def handle_info(:probe, state) do
    Logger.info("[CircuitBreaker] Entering half-open state")
    {:noreply, %{state | circuit: :half_open, failures: 0, successes: 0}}
  end

  defp safe_invoke(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp transition(
         %{circuit: :closed, failures: f, config: %{failure_threshold: t}} = s,
         {:error, _}
       )
       when f + 1 >= t,
       do: open(s)

  defp transition(%{circuit: :closed, failures: f} = s, {:error, _}), do: %{s | failures: f + 1}
  defp transition(%{circuit: :closed} = s, {:ok, _}), do: %{s | failures: 0}

  defp transition(
         %{circuit: :half_open, successes: sc, config: %{success_threshold: t}} = s,
         {:ok, _}
       )
       when sc + 1 >= t do
    Logger.info("[CircuitBreaker] Closing circuit")
    %{s | circuit: :closed, failures: 0, successes: 0}
  end

  defp transition(%{circuit: :half_open, successes: sc} = s, {:ok, _}), do: %{s | successes: sc + 1}
  defp transition(%{circuit: :half_open} = s, {:error, _}), do: open(s)

  defp open(%{config: %{reset_timeout_ms: timeout}} = state) do
    Logger.warning("[CircuitBreaker] Opening circuit")
    Process.send_after(self(), :probe, timeout)
    %{state | circuit: :open, failures: 0, successes: 0}
  end
end
```
