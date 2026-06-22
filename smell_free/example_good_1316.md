**File:** `example_good_1316.md`

```elixir
defmodule TokenBucket do
  @moduledoc """
  A token bucket implementation for fine-grained rate limiting.
  Tokens refill continuously based on a configured rate.
  All configuration is passed explicitly at call time.
  """

  @enforce_keys [:capacity, :refill_rate, :tokens, :last_refill_at]
  defstruct [:capacity, :refill_rate, :tokens, :last_refill_at]

  @type t :: %__MODULE__{
          capacity: number(),
          refill_rate: number(),
          tokens: number(),
          last_refill_at: integer()
        }

  @spec new(number(), number()) :: t()
  def new(capacity, refill_rate)
      when is_number(capacity) and capacity > 0
      when is_number(refill_rate) and refill_rate > 0 do
    %__MODULE__{
      capacity: capacity,
      refill_rate: refill_rate,
      tokens: capacity,
      last_refill_at: System.monotonic_time(:millisecond)
    }
  end

  @spec consume(t(), number()) :: {:allow, t()} | {:deny, t()}
  def consume(%__MODULE__{} = bucket, cost \\ 1) when is_number(cost) and cost > 0 do
    refilled = refill(bucket)

    if refilled.tokens >= cost do
      {:allow, %{refilled | tokens: refilled.tokens - cost}}
    else
      {:deny, refilled}
    end
  end

  @spec tokens_available(t()) :: number()
  def tokens_available(%__MODULE__{} = bucket) do
    refill(bucket).tokens
  end

  @spec time_until_available(t(), number()) :: non_neg_integer()
  def time_until_available(%__MODULE__{} = bucket, cost \\ 1) do
    refilled = refill(bucket)
    deficit = max(0, cost - refilled.tokens)

    if deficit == 0 do
      0
    else
      ceil(deficit / bucket.refill_rate * 1000)
    end
  end

  defp refill(%__MODULE__{last_refill_at: last, refill_rate: rate, tokens: tokens, capacity: cap} = bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed_seconds = (now - last) / 1000
    new_tokens = min(cap, tokens + elapsed_seconds * rate)
    %{bucket | tokens: new_tokens, last_refill_at: now}
  end
end

defmodule TokenBucket.Registry do
  @moduledoc """
  Manages per-key token buckets for multi-tenant rate limiting.
  Buckets are created on demand and stored in an Agent-backed map.
  Provides an explicit API for all reads and mutations.
  """

  use Agent

  alias TokenBucket

  @type bucket_config :: %{capacity: number(), refill_rate: number()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec consume(String.t(), number(), bucket_config()) :: :allow | :deny
  def consume(key, cost, %{capacity: capacity, refill_rate: rate}) do
    Agent.get_and_update(__MODULE__, fn buckets ->
      bucket = Map.get_lazy(buckets, key, fn -> TokenBucket.new(capacity, rate) end)

      case TokenBucket.consume(bucket, cost) do
        {:allow, updated} -> {:allow, Map.put(buckets, key, updated)}
        {:deny, updated} -> {:deny, Map.put(buckets, key, updated)}
      end
    end)
  end

  @spec tokens(String.t(), bucket_config()) :: number()
  def tokens(key, %{capacity: capacity, refill_rate: rate}) do
    Agent.get(__MODULE__, fn buckets ->
      bucket = Map.get_lazy(buckets, key, fn -> TokenBucket.new(capacity, rate) end)
      TokenBucket.tokens_available(bucket)
    end)
  end

  @spec reset(String.t()) :: :ok
  def reset(key), do: Agent.update(__MODULE__, &Map.delete(&1, key))
end
```
