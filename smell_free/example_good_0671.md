```elixir
defmodule CircuitBreaker.State do
  @moduledoc false

  @type status :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          failures: non_neg_integer(),
          failure_threshold: pos_integer(),
          recovery_ms: pos_integer(),
          opened_at: integer() | nil
        }

  defstruct [:name, :opened_at, status: :closed, failures: 0,
             failure_threshold: 5, recovery_ms: 30_000]
end

defmodule CircuitBreaker.Registry do
  @moduledoc """
  Manages a pool of named circuit breakers.

  Each breaker is stored in a public ETS table for lock-free reads while
  state transitions are serialised through the GenServer. Callers can
  `call/3` any registered breaker by name without holding a reference to
  an individual process; the registry acts as the single coordination point
  for the entire breaker fleet.
  """

  use GenServer

  alias CircuitBreaker.State

  @table __MODULE__

  @type opts :: [name: atom(), failure_threshold: pos_integer(), recovery_ms: pos_integer()]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(atom(), keyword()) :: :ok | {:error, :already_registered}
  def register(name, opts \\ []) when is_atom(name) do
    GenServer.call(__MODULE__, {:register, name, opts})
  end

  @spec call(atom(), (-> term())) ::
          {:ok, term()} | {:error, :circuit_open} | {:error, term()}
  def call(name, fun) when is_atom(name) and is_function(fun, 0) do
    case :ets.lookup(@table, name) do
      [{^name, %State{status: :open, opened_at: opened_at, recovery_ms: recovery}}] ->
        if System.monotonic_time(:millisecond) - opened_at >= recovery do
          GenServer.call(__MODULE__, {:try_half_open, name, fun})
        else
          {:error, :circuit_open}
        end

      [{^name, _state}] ->
        GenServer.call(__MODULE__, {:execute, name, fun})

      [] ->
        {:error, :circuit_open}
    end
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:reset, name})
  end

  @spec status(atom()) :: {:ok, State.status()} | {:error, :not_found}
  def status(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, state}] -> {:ok, state.status}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:register, name, opts}, _from, state) do
    if :ets.member(@table, name) do
      {:reply, {:error, :already_registered}, state}
    else
      breaker = %State{
        name: name,
        failure_threshold: Keyword.get(opts, :failure_threshold, 5),
        recovery_ms: Keyword.get(opts, :recovery_ms, 30_000)
      }
      :ets.insert(@table, {name, breaker})
      {:reply, :ok, state}
    end
  end

  def handle_call({:execute, name, fun}, _from, state) do
    [{^name, breaker}] = :ets.lookup(@table, name)
    {reply, updated} = run(breaker, fun)
    :ets.insert(@table, {name, updated})
    {:reply, reply, state}
  end

  def handle_call({:try_half_open, name, fun}, _from, state) do
    [{^name, breaker}] = :ets.lookup(@table, name)
    half_open = %{breaker | status: :half_open}
    {reply, updated} = run(half_open, fun)
    :ets.insert(@table, {name, updated})
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:reset, name}, state) do
    case :ets.lookup(@table, name) do
      [{^name, breaker}] ->
        :ets.insert(@table, {name, %{breaker | status: :closed, failures: 0, opened_at: nil}})
      [] -> :ok
    end
    {:noreply, state}
  end

  defp run(breaker, fun) do
    case safely(fun) do
      {:ok, result} ->
        {{:ok, result}, %{breaker | status: :closed, failures: 0, opened_at: nil}}

      {:error, reason} ->
        new_failures = breaker.failures + 1
        updated =
          if new_failures >= breaker.failure_threshold do
            %{breaker | status: :open, failures: new_failures,
              opened_at: System.monotonic_time(:millisecond)}
          else
            %{breaker | failures: new_failures}
          end
        {{:error, reason}, updated}
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end
end
```
