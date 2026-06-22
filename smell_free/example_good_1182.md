```elixir
defmodule Resilience.CircuitBreaker do
  @moduledoc """
  A GenServer-backed circuit breaker that tracks downstream call outcomes
  and opens the circuit after a configurable failure threshold, preventing
  further calls until a cooldown period elapses and a probe succeeds.
  """

  use GenServer

  @type state_name :: :closed | :open | :half_open
  @type policy :: %{
          failure_threshold: pos_integer(),
          success_threshold: pos_integer(),
          cooldown_ms: pos_integer()
        }

  @type breaker_state :: %{
          name: atom(),
          status: state_name(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          policy: policy()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @spec call(atom(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, :circuit_open | term()}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    GenServer.call(via(name), {:call, fun})
  end

  @spec status(atom()) :: state_name()
  def status(name) when is_atom(name) do
    GenServer.call(via(name), :status)
  end

  @impl GenServer
  def init(opts) do
    policy = %{
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      success_threshold: Keyword.get(opts, :success_threshold, 2),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, 30_000)
    }

    {:ok,
     %{
       name: Keyword.fetch!(opts, :name),
       status: :closed,
       failure_count: 0,
       success_count: 0,
       opened_at: nil,
       policy: policy
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:call, _fun}, _from, %{status: :open} = state) do
    case maybe_transition_to_half_open(state) do
      {:transitioned, new_state} ->
        execute_probe(new_state)

      :still_open ->
        {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:call, fun}, _from, state) do
    case fun.() do
      {:ok, result} ->
        {:reply, {:ok, result}, record_success(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, record_failure(state)}
    end
  end

  @spec maybe_transition_to_half_open(breaker_state()) ::
          {:transitioned, breaker_state()} | :still_open
  defp maybe_transition_to_half_open(%{opened_at: opened_at, policy: policy} = state) do
    elapsed = DateTime.diff(DateTime.utc_now(), opened_at, :millisecond)

    if elapsed >= policy.cooldown_ms do
      {:transitioned, %{state | status: :half_open, success_count: 0}}
    else
      :still_open
    end
  end

  @spec execute_probe(breaker_state()) :: {:reply, term(), breaker_state()}
  defp execute_probe(state) do
    {:reply, {:error, :circuit_open}, state}
  end

  @spec record_success(breaker_state()) :: breaker_state()
  defp record_success(%{status: :half_open, policy: policy} = state) do
    updated = %{state | success_count: state.success_count + 1}

    if updated.success_count >= policy.success_threshold do
      %{updated | status: :closed, failure_count: 0, success_count: 0, opened_at: nil}
    else
      updated
    end
  end

  defp record_success(state), do: %{state | failure_count: 0}

  @spec record_failure(breaker_state()) :: breaker_state()
  defp record_failure(%{policy: policy} = state) do
    updated = %{state | failure_count: state.failure_count + 1}

    if updated.failure_count >= policy.failure_threshold do
      %{updated | status: :open, opened_at: DateTime.utc_now()}
    else
      updated
    end
  end

  @spec via(atom()) :: {:via, Registry, {Resilience.BreakerRegistry, atom()}}
  defp via(name), do: {:via, Registry, {Resilience.BreakerRegistry, name}}
end
```
