```elixir
defmodule Throttle.Bucket do
  @moduledoc """
  Immutable token-bucket state for the rate limiter.

  A bucket has a fixed capacity and a current token count. Tokens are
  consumed via `take/2` and replenished via `refill/2`. All operations
  return new structs, leaving the original value unchanged.
  """

  @type t :: %__MODULE__{
          capacity: pos_integer(),
          tokens: non_neg_integer()
        }

  defstruct [:capacity, :tokens]

  @spec new(pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity, tokens: capacity}
  end

  @spec take(t(), pos_integer()) :: {:ok, t()} | {:error, :rate_limited}
  def take(%__MODULE__{tokens: available} = bucket, amount)
      when is_integer(amount) and amount > 0 and available >= amount do
    {:ok, %{bucket | tokens: available - amount}}
  end

  def take(%__MODULE__{}, _amount), do: {:error, :rate_limited}

  @spec refill(t(), pos_integer()) :: t()
  def refill(%__MODULE__{tokens: current, capacity: cap} = bucket, amount)
      when is_integer(amount) and amount > 0 do
    %{bucket | tokens: min(cap, current + amount)}
  end

  @spec available(t()) :: non_neg_integer()
  def available(%__MODULE__{tokens: tokens}), do: tokens
end

defmodule Throttle.RateLimiter do
  @moduledoc """
  A named, supervised token-bucket rate limiter.

  Each limiter process manages one bucket that refills at a fixed rate on
  a configurable interval. Callers consume tokens via `request/2`; when
  the bucket is empty, subsequent calls receive `{:error, :rate_limited}`
  until the next refill cycle.
  """

  use GenServer

  alias Throttle.Bucket

  @type opts :: [
          name: atom(),
          capacity: pos_integer(),
          refill_amount: pos_integer(),
          refill_interval_ms: pos_integer()
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

  @spec available_tokens(atom()) :: non_neg_integer()
  def available_tokens(name) when is_atom(name) do
    GenServer.call(name, :available_tokens)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    refill_amount = Keyword.get(opts, :refill_amount, 1)
    interval = Keyword.get(opts, :refill_interval_ms, 1_000)

    schedule_refill(interval)

    {:ok, %{bucket: Bucket.new(capacity), refill_amount: refill_amount, interval: interval}}
  end

  @impl GenServer
  def handle_call({:request, tokens}, _from, %{bucket: bucket} = state) do
    case Bucket.take(bucket, tokens) do
      {:ok, updated} -> {:reply, :ok, %{state | bucket: updated}}
      {:error, :rate_limited} -> {:reply, {:error, :rate_limited}, state}
    end
  end

  def handle_call(:available_tokens, _from, %{bucket: bucket} = state) do
    {:reply, Bucket.available(bucket), state}
  end

  @impl GenServer
  def handle_info(:refill, state) do
    updated_bucket = Bucket.refill(state.bucket, state.refill_amount)
    schedule_refill(state.interval)
    {:noreply, %{state | bucket: updated_bucket}}
  end

  defp schedule_refill(interval) do
    Process.send_after(self(), :refill, interval)
  end
end

defmodule Throttle.Supervisor do
  @moduledoc """
  Supervises all rate limiter instances created at application startup
  and allows additional limiters to be added at runtime.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_limiter(Throttle.RateLimiter.opts()) :: DynamicSupervisor.on_start_child()
  def start_limiter(opts) do
    DynamicSupervisor.start_child(Throttle.DynamicSupervisor, {Throttle.RateLimiter, opts})
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Throttle.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
