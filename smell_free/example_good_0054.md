```elixir
defmodule RateLimiter.TokenBucket do
  @moduledoc """
  A token-bucket rate limiter backed by a GenServer. Each named bucket has
  a configurable capacity and refill rate. Tokens are consumed on request
  and replenished continuously over time. Buckets are created on first use
  and persist until the process is stopped.
  """

  use GenServer

  @type bucket_id :: String.t()
  @type bucket_config :: %{capacity: pos_integer(), refill_per_second: pos_integer()}
  @type bucket :: %{
          tokens: float(),
          capacity: pos_integer(),
          refill_per_second: pos_integer(),
          last_refill_at: integer()
        }

  @doc "Starts the token bucket store, registering it under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume one token from the named bucket. Creates the bucket
  with `config` on first call. Returns `:ok` when a token is available or
  `{:error, :rate_limited}` when the bucket is empty.
  """
  @spec consume(bucket_id(), bucket_config()) :: :ok | {:error, :rate_limited}
  def consume(bucket_id, %{capacity: _, refill_per_second: _} = config)
      when is_binary(bucket_id) do
    GenServer.call(__MODULE__, {:consume, bucket_id, config})
  end

  @doc """
  Returns the current (refilled) token count for the bucket, or `nil` if
  the bucket has not been created yet.
  """
  @spec token_count(bucket_id()) :: float() | nil
  def token_count(bucket_id) when is_binary(bucket_id) do
    GenServer.call(__MODULE__, {:token_count, bucket_id})
  end

  @doc "Removes all buckets from the store."
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{buckets: %{}}}

  @impl GenServer
  def handle_call({:consume, id, config}, _from, state) do
    bucket = get_or_create_bucket(state.buckets, id, config)
    refilled = refill(bucket)

    if refilled.tokens >= 1.0 do
      updated = %{refilled | tokens: refilled.tokens - 1.0}
      {:reply, :ok, put_in(state, [:buckets, id], updated)}
    else
      {:reply, {:error, :rate_limited}, put_in(state, [:buckets, id], refilled)}
    end
  end

  def handle_call({:token_count, id}, _from, state) do
    count =
      case Map.get(state.buckets, id) do
        nil -> nil
        bucket -> refill(bucket).tokens
      end

    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast(:reset, state), do: {:noreply, %{state | buckets: %{}}}

  defp get_or_create_bucket(buckets, id, config) do
    Map.get_lazy(buckets, id, fn ->
      %{
        tokens: config.capacity * 1.0,
        capacity: config.capacity,
        refill_per_second: config.refill_per_second,
        last_refill_at: System.monotonic_time(:millisecond)
      }
    end)
  end

  defp refill(%{last_refill_at: last, refill_per_second: rate, capacity: cap} = bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed = (now - last) / 1_000
    new_tokens = min(cap * 1.0, bucket.tokens + elapsed * rate)
    %{bucket | tokens: new_tokens, last_refill_at: now}
  end
end
```
