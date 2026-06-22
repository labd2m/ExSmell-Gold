```elixir
defmodule RateLimit.TokenBucket do
  @moduledoc """
  A pure functional token-bucket rate limiter. The bucket is a plain struct
  with no process or timer dependencies; callers pass the current time and
  receive back the updated bucket and the decision. This design makes the
  limiter trivially testable and composable — it can be stored in a GenServer,
  an ETS table, or a database row, depending on the consistency requirements
  of the call site. No global state is ever mutated here.
  """

  @enforce_keys [:capacity, :tokens, :refill_rate_per_second, :last_refill_at]
  defstruct [:capacity, :tokens, :refill_rate_per_second, :last_refill_at]

  @type t :: %__MODULE__{
          capacity: number(),
          tokens: number(),
          refill_rate_per_second: number(),
          last_refill_at: integer()
        }

  @type decision :: {:allow, t()} | {:deny, t()}

  @doc """
  Creates a full token bucket with `capacity` tokens refilling at
  `refill_rate_per_second` tokens per second.
  """
  @spec new(number(), number()) :: t()
  def new(capacity, refill_rate_per_second)
      when is_number(capacity) and capacity > 0 and
             is_number(refill_rate_per_second) and refill_rate_per_second > 0 do
    %__MODULE__{
      capacity: capacity,
      tokens: capacity,
      refill_rate_per_second: refill_rate_per_second,
      last_refill_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Attempts to consume `tokens` from the bucket as of `now_ms`.
  Refills the bucket based on elapsed time before checking capacity.
  Returns `{:allow, updated_bucket}` or `{:deny, unchanged_bucket}`.
  """
  @spec consume(t(), number(), integer()) :: decision()
  def consume(%__MODULE__{} = bucket, tokens \\ 1, now_ms \\ System.monotonic_time(:millisecond))
      when is_number(tokens) and tokens > 0 and is_integer(now_ms) do
    refilled = refill(bucket, now_ms)

    if refilled.tokens >= tokens do
      updated = %{refilled | tokens: refilled.tokens - tokens}
      {:allow, updated}
    else
      {:deny, refilled}
    end
  end

  @doc """
  Returns the current token count after applying elapsed refill,
  without consuming any tokens.
  """
  @spec peek(t(), integer()) :: number()
  def peek(%__MODULE__{} = bucket, now_ms \\ System.monotonic_time(:millisecond)) do
    refill(bucket, now_ms).tokens
  end

  @doc """
  Returns the estimated number of milliseconds until `needed_tokens`
  will be available in the bucket. Returns `0` when already available.
  """
  @spec wait_ms(t(), number(), integer()) :: non_neg_integer()
  def wait_ms(%__MODULE__{} = bucket, needed_tokens, now_ms \\ System.monotonic_time(:millisecond)) do
    refilled = refill(bucket, now_ms)
    shortfall = needed_tokens - refilled.tokens

    if shortfall <= 0 do
      0
    else
      ceil(shortfall / refilled.refill_rate_per_second * 1_000)
    end
  end

  @doc """
  Returns a percentage (0.0–1.0) representing how full the bucket currently is.
  """
  @spec fill_ratio(t(), integer()) :: float()
  def fill_ratio(%__MODULE__{} = bucket, now_ms \\ System.monotonic_time(:millisecond)) do
    refilled = refill(bucket, now_ms)
    refilled.tokens / refilled.capacity
  end

  @doc """
  Resets the bucket to full capacity as of `now_ms`.
  """
  @spec reset(t(), integer()) :: t()
  def reset(%__MODULE__{} = bucket, now_ms \\ System.monotonic_time(:millisecond)) do
    %{bucket | tokens: bucket.capacity, last_refill_at: now_ms}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp refill(%__MODULE__{} = bucket, now_ms) do
    elapsed_seconds = max(0, (now_ms - bucket.last_refill_at) / 1_000)
    added = elapsed_seconds * bucket.refill_rate_per_second
    new_tokens = min(bucket.capacity, bucket.tokens + added)

    %{bucket | tokens: new_tokens, last_refill_at: now_ms}
  end
end
```
