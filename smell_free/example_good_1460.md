```elixir
defmodule RateLimiter.Bucket do
  use GenServer

  @moduledoc """
  A token-bucket rate limiter for a named resource key.
  Tokens refill at a fixed rate and requests consume one token each.
  Instances are created on demand by `RateLimiter.Registry` and
  supervised via `RateLimiter.DynamicSupervisor`.
  """

  @type config :: %{capacity: pos_integer(), refill_per_second: pos_integer()}
  @type state :: %{key: String.t(), tokens: non_neg_integer(), config: config(), last_refill_ms: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    config = Keyword.fetch!(opts, :config)
    GenServer.start_link(__MODULE__, {key, config}, name: via(key))
  end

  @spec check_and_consume(String.t()) :: :allowed | :denied
  def check_and_consume(key) do
    GenServer.call(via(key), :check_and_consume)
  end

  @spec remaining_tokens(String.t()) :: non_neg_integer()
  def remaining_tokens(key) do
    GenServer.call(via(key), :remaining)
  end

  @impl GenServer
  def init({key, config}) do
    state = %{
      key: key,
      tokens: config.capacity,
      config: config,
      last_refill_ms: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:check_and_consume, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    state_after_refill = apply_refill(state, now_ms)

    if state_after_refill.tokens > 0 do
      {:reply, :allowed, %{state_after_refill | tokens: state_after_refill.tokens - 1}}
    else
      {:reply, :denied, state_after_refill}
    end
  end

  def handle_call(:remaining, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    refilled = apply_refill(state, now_ms)
    {:reply, refilled.tokens, refilled}
  end

  defp apply_refill(state, now_ms) do
    elapsed_ms = now_ms - state.last_refill_ms
    refill_amount = floor(elapsed_ms / 1000 * state.config.refill_per_second)

    if refill_amount > 0 do
      new_tokens = min(state.tokens + refill_amount, state.config.capacity)
      %{state | tokens: new_tokens, last_refill_ms: now_ms}
    else
      state
    end
  end

  defp via(key), do: {:via, Registry, {RateLimiter.Registry, key}}
end

defmodule RateLimiter do
  alias RateLimiter.Bucket

  @moduledoc """
  Public interface for the rate limiting subsystem.
  Buckets are lazily initialized on first access and supervised persistently.
  """

  @default_config %{capacity: 100, refill_per_second: 10}

  @spec allow?(String.t(), map()) :: boolean()
  def allow?(key, config \\ @default_config) when is_binary(key) do
    ensure_bucket(key, config)

    case Bucket.check_and_consume(key) do
      :allowed -> true
      :denied -> false
    end
  end

  defp ensure_bucket(key, config) do
    case DynamicSupervisor.start_child(
           RateLimiter.DynamicSupervisor,
           {Bucket, key: key, config: config}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
```
