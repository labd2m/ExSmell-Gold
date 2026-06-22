```elixir
defmodule RateLimit.Bucket do
  @moduledoc """
  A token-bucket rate limiter backed by a named GenServer.
  Each bucket is identified by a string key and refills at a configured rate.
  Buckets are started under a supervisor via `RateLimit.BucketSupervisor`.
  """

  use GenServer

  @type config :: %{
          capacity: pos_integer(),
          refill_per_second: pos_integer()
        }

  @type state :: %{
          key: String.t(),
          tokens: float(),
          capacity: pos_integer(),
          refill_per_second: pos_integer(),
          last_refill_ms: integer()
        }

  @spec child_spec({String.t(), config()}) :: Supervisor.child_spec()
  def child_spec({key, config}) do
    %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [key, config]},
      restart: :permanent
    }
  end

  @spec start_link(String.t(), config()) :: GenServer.on_start()
  def start_link(key, config) when is_binary(key) and is_map(config) do
    GenServer.start_link(__MODULE__, {key, config}, name: via(key))
  end

  @spec check_and_consume(String.t(), pos_integer()) ::
          {:ok, :allowed} | {:error, :rate_limited} | {:error, :not_found}
  def check_and_consume(key, tokens \\ 1)
      when is_binary(key) and is_integer(tokens) and tokens > 0 do
    case Registry.lookup(RateLimit.Registry, key) do
      [{pid, _}] -> GenServer.call(pid, {:consume, tokens})
      [] -> {:error, :not_found}
    end
  end

  @spec tokens_remaining(String.t()) :: {:ok, float()} | {:error, :not_found}
  def tokens_remaining(key) when is_binary(key) do
    case Registry.lookup(RateLimit.Registry, key) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :tokens)}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init({key, %{capacity: capacity, refill_per_second: rate}}) do
    state = %{
      key: key,
      tokens: capacity * 1.0,
      capacity: capacity,
      refill_per_second: rate,
      last_refill_ms: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:consume, requested}, _from, state) do
    refreshed = refill(state)

    if refreshed.tokens >= requested do
      updated = Map.update!(refreshed, :tokens, &(&1 - requested))
      {:reply, {:ok, :allowed}, updated}
    else
      {:reply, {:error, :rate_limited}, refreshed}
    end
  end

  def handle_call(:tokens, _from, state) do
    refreshed = refill(state)
    {:reply, refreshed.tokens, refreshed}
  end

  defp refill(%{tokens: tokens, capacity: cap, refill_per_second: rate, last_refill_ms: last} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed_s = (now - last) / 1_000
    new_tokens = min(cap * 1.0, tokens + elapsed_s * rate)
    %{state | tokens: new_tokens, last_refill_ms: now}
  end

  defp via(key), do: {:via, Registry, {RateLimit.Registry, key}}
end
```
