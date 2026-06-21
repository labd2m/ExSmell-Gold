```elixir
defmodule Network.CircuitBreaker do
  @moduledoc """
  Implements the circuit-breaker pattern as a GenServer. The breaker tracks
  consecutive failures for a named dependency. After `failure_threshold`
  failures the circuit opens and calls return `{:error, :circuit_open}`
  immediately. After `reset_timeout_ms` the circuit moves to half-open,
  allowing one probe call. A successful probe closes the circuit; a failed
  probe reopens it.
  """

  use GenServer

  @type breaker_name :: atom()
  @type breaker_state :: :closed | :open | :half_open
  @type call_fn :: (-> {:ok, term()} | {:error, term()})

  @default_failure_threshold 5
  @default_reset_timeout_ms 30_000

  @doc "Starts a named circuit breaker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Calls `fun` through the circuit breaker identified by `name`.
  Returns `{:error, :circuit_open}` immediately when the circuit is open.
  """
  @spec call(breaker_name(), call_fn()) ::
          {:ok, term()} | {:error, :circuit_open | term()}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.call(name, {:call, fun})
  end

  @doc "Returns the current state of the named circuit breaker."
  @spec state(breaker_name()) :: %{state: breaker_state(), failures: non_neg_integer()}
  def state(name) when is_atom(name), do: GenServer.call(name, :state)

  @doc "Manually resets the breaker to closed state with zero failures."
  @spec reset(breaker_name()) :: :ok
  def reset(name) when is_atom(name), do: GenServer.cast(name, :reset)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       state: :closed,
       failures: 0,
       failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
       reset_timeout_ms: Keyword.get(opts, :reset_timeout_ms, @default_reset_timeout_ms)
     }}
  end

  @impl GenServer
  def handle_call({:call, _fun}, _from, %{state: :open} = breaker) do
    {:reply, {:error, :circuit_open}, breaker}
  end

  def handle_call({:call, fun}, _from, breaker) do
    result = fun.()
    new_breaker = record_outcome(result, breaker)
    {:reply, result, new_breaker}
  end

  def handle_call(:state, _from, breaker) do
    {:reply, Map.take(breaker, [:state, :failures]), breaker}
  end

  @impl GenServer
  def handle_cast(:reset, breaker) do
    {:noreply, %{breaker | state: :closed, failures: 0}}
  end

  @impl GenServer
  def handle_info(:attempt_reset, breaker) do
    {:noreply, %{breaker | state: :half_open}}
  end

  defp record_outcome({:ok, _}, %{state: :half_open} = breaker) do
    %{breaker | state: :closed, failures: 0}
  end

  defp record_outcome({:ok, _}, breaker), do: %{breaker | failures: 0}

  defp record_outcome({:error, _}, %{state: :half_open} = breaker) do
    schedule_reset(breaker.reset_timeout_ms)
    %{breaker | state: :open}
  end

  defp record_outcome({:error, _}, breaker) do
    new_failures = breaker.failures + 1

    if new_failures >= breaker.failure_threshold do
      schedule_reset(breaker.reset_timeout_ms)
      %{breaker | state: :open, failures: new_failures}
    else
      %{breaker | failures: new_failures}
    end
  end

  defp schedule_reset(timeout_ms) do
    Process.send_after(self(), :attempt_reset, timeout_ms)
  end
end
```
