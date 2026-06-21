```elixir
defmodule MyApp.HTTP.CircuitBreaker do
  @moduledoc """
  A GenServer-backed circuit breaker for outbound HTTP calls. Tracks
  consecutive failures per named service and opens the circuit when the
  failure threshold is exceeded, short-circuiting calls with
  `{:error, :circuit_open}` to give downstream services time to recover.

  The circuit transitions through three states:
  * `:closed`   — normal operation; calls are forwarded.
  * `:open`     — calls are rejected immediately for `open_duration_ms`.
  * `:half_open`— one probe call is allowed through after the open period;
                  success closes the circuit, failure re-opens it.

  Start this module under the application supervisor:

      children = [MyApp.HTTP.CircuitBreaker]
  """

  use GenServer

  require Logger

  @default_threshold 5
  @default_open_ms 30_000

  @type service :: atom()
  @type circuit_state :: :closed | :open | :half_open
  @type breaker :: %{
          state: circuit_state(),
          failures: non_neg_integer(),
          opened_at: integer() | nil
        }

  @doc "Starts the circuit breaker registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Wraps `fun/0` with circuit breaker protection for `service`.
  Returns `{:error, :circuit_open}` when the circuit is open and
  not yet ready for a probe call.
  """
  @spec call(service(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open} | {:error, term()}
  def call(service, fun) when is_atom(service) and is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:request, service}) do
      :allow ->
        result = fun.()
        GenServer.cast(__MODULE__, {:result, service, outcome(result)})
        result

      :reject ->
        {:error, :circuit_open}
    end
  end

  @doc "Returns the current circuit state for `service`."
  @spec state(service()) :: circuit_state()
  def state(service) when is_atom(service) do
    GenServer.call(__MODULE__, {:state, service})
  end

  @doc "Manually resets the circuit for `service` to closed."
  @spec reset(service()) :: :ok
  def reset(service) when is_atom(service) do
    GenServer.cast(__MODULE__, {:reset, service})
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{
      breakers: %{},
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      open_ms: Keyword.get(opts, :open_duration_ms, @default_open_ms)
    }}
  end

  @impl GenServer
  def handle_call({:request, service}, _from, state) do
    breaker = get_or_init(state.breakers, service)
    {decision, updated_breaker} = evaluate(breaker, state.open_ms)
    {:reply, decision, %{state | breakers: Map.put(state.breakers, service, updated_breaker)}}
  end

  @impl GenServer
  def handle_call({:state, service}, _from, state) do
    circuit_state = state.breakers |> Map.get(service, init_breaker()) |> Map.get(:state)
    {:reply, circuit_state, state}
  end

  @impl GenServer
  def handle_cast({:result, service, :ok}, state) do
    breaker = get_or_init(state.breakers, service)
    closed = %{breaker | state: :closed, failures: 0, opened_at: nil}
    {:noreply, %{state | breakers: Map.put(state.breakers, service, closed)}}
  end

  @impl GenServer
  def handle_cast({:result, service, :error}, state) do
    breaker = get_or_init(state.breakers, service)
    new_failures = breaker.failures + 1

    updated =
      if new_failures >= state.threshold do
        Logger.warning("circuit_breaker_opened", service: service)
        %{breaker | state: :open, failures: new_failures, opened_at: mono_ms()}
      else
        %{breaker | failures: new_failures}
      end

    {:noreply, %{state | breakers: Map.put(state.breakers, service, updated)}}
  end

  @impl GenServer
  def handle_cast({:reset, service}, state) do
    {:noreply, %{state | breakers: Map.put(state.breakers, service, init_breaker())}}
  end

  @spec evaluate(breaker(), pos_integer()) :: {:allow | :reject, breaker()}
  defp evaluate(%{state: :closed} = b, _open_ms), do: {:allow, b}

  defp evaluate(%{state: :open, opened_at: opened_at} = b, open_ms) do
    if mono_ms() - opened_at >= open_ms do
      {:allow, %{b | state: :half_open}}
    else
      {:reject, b}
    end
  end

  defp evaluate(%{state: :half_open} = b, _open_ms), do: {:allow, b}

  @spec get_or_init(%{service() => breaker()}, service()) :: breaker()
  defp get_or_init(breakers, service), do: Map.get(breakers, service, init_breaker())

  @spec init_breaker() :: breaker()
  defp init_breaker, do: %{state: :closed, failures: 0, opened_at: nil}

  @spec outcome({:ok, term()} | {:error, term()}) :: :ok | :error
  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, _}), do: :error

  @spec mono_ms() :: integer()
  defp mono_ms, do: System.monotonic_time(:millisecond)
end
```
