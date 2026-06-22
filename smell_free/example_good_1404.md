```elixir
defmodule Mailer.Delivery.RateLimiter do
  @moduledoc """
  A GenServer that enforces per-recipient email send rate limits using a
  token-bucket strategy. Limits are configured at startup via keyword options.
  """

  use GenServer

  @type bucket :: %{tokens: non_neg_integer(), last_refill: integer()}
  @type state :: %{
          buckets: %{String.t() => bucket()},
          capacity: pos_integer(),
          refill_rate: pos_integer(),
          refill_interval_ms: pos_integer()
        }

  @doc """
  Starts the RateLimiter linked to the calling process.

  ## Options
    - `:capacity` - maximum burst tokens per recipient (default: 5)
    - `:refill_rate` - tokens added per interval (default: 1)
    - `:refill_interval_ms` - refill interval in milliseconds (default: 60_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume one send token for the given recipient email.

  Returns `:ok` if allowed, `{:error, :rate_limited}` if the bucket is empty.
  """
  @spec check_and_consume(String.t()) :: :ok | {:error, :rate_limited}
  def check_and_consume(recipient) when is_binary(recipient) do
    GenServer.call(__MODULE__, {:check_and_consume, recipient})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      buckets: %{},
      capacity: Keyword.get(opts, :capacity, 5),
      refill_rate: Keyword.get(opts, :refill_rate, 1),
      refill_interval_ms: Keyword.get(opts, :refill_interval_ms, 60_000)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check_and_consume, recipient}, _from, state) do
    now = System.monotonic_time(:millisecond)
    bucket = Map.get(state.buckets, recipient, new_bucket(state.capacity, now))
    refilled_bucket = apply_refill(bucket, state, now)

    {reply, updated_bucket} = consume_token(refilled_bucket, state.capacity)

    new_state = %{state | buckets: Map.put(state.buckets, recipient, updated_bucket)}
    {:reply, reply, new_state}
  end

  defp new_bucket(capacity, now) do
    %{tokens: capacity, last_refill: now}
  end

  defp apply_refill(bucket, state, now) do
    elapsed_ms = now - bucket.last_refill
    intervals_elapsed = div(elapsed_ms, state.refill_interval_ms)

    if intervals_elapsed > 0 do
      added = intervals_elapsed * state.refill_rate
      new_tokens = min(bucket.tokens + added, state.capacity)
      new_last_refill = bucket.last_refill + intervals_elapsed * state.refill_interval_ms
      %{bucket | tokens: new_tokens, last_refill: new_last_refill}
    else
      bucket
    end
  end

  defp consume_token(%{tokens: 0} = bucket, _capacity) do
    {{:error, :rate_limited}, bucket}
  end

  defp consume_token(bucket, _capacity) do
    {:ok, %{bucket | tokens: bucket.tokens - 1}}
  end
end
```
