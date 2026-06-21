```elixir
defmodule Metrics.Counter do
  @moduledoc """
  A named, supervised counter GenServer. Each counter holds a current value
  and an optional high-water mark. Counters are registered by name so callers
  never need to track PIDs. Values are never held in module attributes or
  process dictionaries — state lives exclusively in the GenServer state map.
  """

  use GenServer

  @type counter_name :: atom()
  @type counter_state :: %{value: non_neg_integer(), hwm: non_neg_integer()}

  @doc "Starts a counter and registers it by name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Increments the counter by `amount` (default 1)."
  @spec increment(counter_name(), pos_integer()) :: :ok
  def increment(name, amount \\ 1) when is_atom(name) and is_integer(amount) and amount > 0 do
    GenServer.cast(name, {:increment, amount})
  end

  @doc "Resets the counter value to zero. The high-water mark is preserved."
  @spec reset(counter_name()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(name, :reset)
  end

  @doc "Returns the current value and high-water mark."
  @spec read(counter_name()) :: {:ok, counter_state()}
  def read(name) when is_atom(name) do
    {:ok, GenServer.call(name, :read)}
  end

  @doc "Returns the current value only."
  @spec value(counter_name()) :: non_neg_integer()
  def value(name) when is_atom(name) do
    GenServer.call(name, :value)
  end

  @impl GenServer
  def init(opts) do
    initial = Keyword.get(opts, :initial_value, 0)
    {:ok, %{value: initial, hwm: initial}}
  end

  @impl GenServer
  def handle_cast({:increment, amount}, state) do
    new_value = state.value + amount
    new_hwm = max(new_value, state.hwm)
    {:noreply, %{state | value: new_value, hwm: new_hwm}}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | value: 0}}
  end

  @impl GenServer
  def handle_call(:read, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:value, _from, state) do
    {:reply, state.value, state}
  end
end

defmodule Metrics.CounterSupervisor do
  @moduledoc """
  Supervises a fixed set of named metric counters defined at compile time
  via application configuration. Each counter is a permanent child that
  restarts automatically after a crash, preserving observability guarantees.
  """

  use Supervisor

  @doc "Starts the counter supervisor linked to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    counters = Application.get_env(:my_app, :metric_counters, [:requests, :errors, :cache_hits])

    children = Enum.map(counters, fn name ->
      Supervisor.child_spec({Metrics.Counter, name: name}, id: name)
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
