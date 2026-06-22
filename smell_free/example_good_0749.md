```elixir
defmodule LeakyBucket do
  @moduledoc """
  A leaky-bucket rate limiter that smooths bursty traffic into a steady
  output rate.

  Unlike a token-bucket which refills tokens on a timer, the leaky bucket
  drains at a fixed rate regardless of when requests arrive. Requests are
  accepted if the current fill level plus the incoming request size does not
  exceed capacity; otherwise they are rejected. The fill level is computed
  lazily on each request using elapsed time since the last drain calculation,
  avoiding the need for a background timer process.
  """

  use GenServer

  @type opts :: [
          name: atom(),
          capacity: pos_integer(),
          drain_rate_per_second: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec request(atom(), pos_integer()) :: :ok | {:error, :rate_limited}
  def request(name, tokens \\ 1)
      when is_atom(name) and is_integer(tokens) and tokens > 0 do
    GenServer.call(name, {:request, tokens})
  end

  @spec fill_level(atom()) :: float()
  def fill_level(name) when is_atom(name) do
    GenServer.call(name, :fill_level)
  end

  @spec reset(atom()) :: :ok
  def reset(name) when is_atom(name) do
    GenServer.cast(name, :reset)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      capacity: Keyword.fetch!(opts, :capacity),
      drain_rate: Keyword.fetch!(opts, :drain_rate_per_second),
      level: 0.0,
      last_checked_at: monotonic_seconds()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, tokens}, _from, state) do
    {current_level, updated_time} = drain(state)

    new_level = current_level + tokens

    if new_level <= state.capacity do
      {:reply, :ok, %{state | level: new_level, last_checked_at: updated_time}}
    else
      {:reply, {:error, :rate_limited}, %{state | level: current_level, last_checked_at: updated_time}}
    end
  end

  def handle_call(:fill_level, _from, state) do
    {current_level, updated_time} = drain(state)
    {:reply, current_level, %{state | level: current_level, last_checked_at: updated_time}}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply, %{state | level: 0.0, last_checked_at: monotonic_seconds()}}
  end

  defp drain(state) do
    now = monotonic_seconds()
    elapsed = now - state.last_checked_at
    drained = elapsed * state.drain_rate
    new_level = max(0.0, state.level - drained)
    {new_level, now}
  end

  defp monotonic_seconds do
    System.monotonic_time(:millisecond) / 1_000.0
  end
end

defmodule LeakyBucket.Supervisor do
  @moduledoc """
  Supervises a collection of named leaky-bucket rate limiters.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_limiter(LeakyBucket.opts()) :: DynamicSupervisor.on_start_child()
  def start_limiter(opts) do
    DynamicSupervisor.start_child(__MODULE__, {LeakyBucket, opts})
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```
