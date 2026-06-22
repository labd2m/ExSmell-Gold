```elixir
defmodule Infra.CircuitBreaker do
  @moduledoc """
  GenServer implementing the circuit breaker pattern for protecting
  downstream service calls from cascading failures.

  The breaker transitions between three states: `:closed` (normal
  operation), `:open` (blocking calls after threshold failures),
  and `:half_open` (probing recovery with a single trial call).

  State transitions are driven by call outcomes reported through
  `record_success/1` and `record_failure/1`.
  """

  use GenServer

  require Logger

  @type breaker_name :: atom()
  @type breaker_state :: :closed | :open | :half_open
  @type call_result :: :allow | {:deny, :circuit_open}

  @type state :: %{
          name: breaker_name(),
          status: breaker_state(),
          failure_count: non_neg_integer(),
          failure_threshold: pos_integer(),
          reset_timeout_ms: pos_integer(),
          opened_at: integer() | nil
        }

  @default_failure_threshold 5
  @default_reset_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc """
  Returns `:allow` if the breaker is closed or half-open, or
  `{:deny, :circuit_open}` if the breaker is open.
  """
  @spec check(breaker_name()) :: call_result()
  def check(name) when is_atom(name) do
    GenServer.call(via(name), :check)
  end

  @doc "Records a successful downstream call, contributing to breaker recovery."
  @spec record_success(breaker_name()) :: :ok
  def record_success(name) when is_atom(name) do
    GenServer.cast(via(name), :record_success)
  end

  @doc "Records a failed downstream call, potentially tripping the breaker."
  @spec record_failure(breaker_name()) :: :ok
  def record_failure(name) when is_atom(name) do
    GenServer.cast(via(name), :record_failure)
  end

  @doc "Returns the current internal state of the breaker."
  @spec status(breaker_name()) :: breaker_state()
  def status(name) when is_atom(name) do
    GenServer.call(via(name), :status)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      status: :closed,
      failure_count: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      reset_timeout_ms: Keyword.get(opts, :reset_timeout_ms, @default_reset_timeout_ms),
      opened_at: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:check, _from, %{status: :closed} = state) do
    {:reply, :allow, state}
  end

  def handle_call(:check, _from, %{status: :half_open} = state) do
    {:reply, :allow, state}
  end

  def handle_call(:check, _from, %{status: :open} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.opened_at

    if elapsed >= state.reset_timeout_ms do
      Logger.info("Circuit breaker #{state.name} transitioning to half-open.")
      {:reply, :allow, %{state | status: :half_open}}
    else
      {:reply, {:deny, :circuit_open}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_cast(:record_success, %{status: :half_open} = state) do
    Logger.info("Circuit breaker #{state.name} closed after successful probe.")
    {:noreply, %{state | status: :closed, failure_count: 0, opened_at: nil}}
  end

  def handle_cast(:record_success, state) do
    {:noreply, %{state | failure_count: max(0, state.failure_count - 1)}}
  end

  def handle_cast(:record_failure, %{status: :half_open} = state) do
    Logger.warning("Circuit breaker #{state.name} re-opened after failed probe.")
    {:noreply, %{state | status: :open, opened_at: System.monotonic_time(:millisecond)}}
  end

  def handle_cast(:record_failure, %{status: :closed} = state) do
    updated_count = state.failure_count + 1

    if updated_count >= state.failure_threshold do
      Logger.warning("Circuit breaker #{state.name} opened after #{updated_count} failures.")
      {:noreply, %{state | status: :open, failure_count: updated_count, opened_at: System.monotonic_time(:millisecond)}}
    else
      {:noreply, %{state | failure_count: updated_count}}
    end
  end

  def handle_cast(:record_failure, state) do
    {:noreply, state}
  end

  defp via(name) do
    {:via, Registry, {Infra.BreakerRegistry, name}}
  end
end
```
