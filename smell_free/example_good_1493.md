```elixir
defmodule RateLimit.TokenBucket do
  @moduledoc """
  Token bucket rate limiter for a named key, backed by ETS for low-latency access.
  Provides per-key rate limiting with configurable capacity and refill rates.
  """

  @type bucket_key :: String.t()
  @type config :: %{capacity: pos_integer(), refill_rate: pos_integer(), refill_interval_ms: pos_integer()}
  @type bucket :: %{tokens: non_neg_integer(), last_refill: integer()}

  @table :rate_limit_buckets

  @spec setup() :: :ok
  def setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    end

    :ok
  end

  @spec allow?(bucket_key(), config()) :: boolean()
  def allow?(key, %{capacity: capacity, refill_rate: refill_rate, refill_interval_ms: interval_ms})
      when is_binary(key) do
    now = System.monotonic_time(:millisecond)
    bucket = get_or_create_bucket(key, capacity, now)
    refilled = apply_refill(bucket, now, refill_rate, interval_ms, capacity)

    if refilled.tokens >= 1 do
      updated = %{refilled | tokens: refilled.tokens - 1}
      :ets.insert(@table, {key, updated})
      true
    else
      :ets.insert(@table, {key, refilled})
      false
    end
  end

  @spec reset(bucket_key()) :: :ok
  def reset(key) when is_binary(key) do
    :ets.delete(@table, key)
    :ok
  end

  @spec remaining(bucket_key(), config()) :: non_neg_integer()
  def remaining(key, %{capacity: capacity, refill_rate: refill_rate, refill_interval_ms: interval_ms}) do
    now = System.monotonic_time(:millisecond)
    bucket = get_or_create_bucket(key, capacity, now)
    apply_refill(bucket, now, refill_rate, interval_ms, capacity).tokens
  end

  @spec get_or_create_bucket(bucket_key(), pos_integer(), integer()) :: bucket()
  defp get_or_create_bucket(key, capacity, now) do
    case :ets.lookup(@table, key) do
      [{^key, bucket}] -> bucket
      [] -> %{tokens: capacity, last_refill: now}
    end
  end

  @spec apply_refill(bucket(), integer(), pos_integer(), pos_integer(), pos_integer()) :: bucket()
  defp apply_refill(bucket, now, refill_rate, interval_ms, capacity) do
    elapsed_intervals = div(now - bucket.last_refill, interval_ms)

    if elapsed_intervals > 0 do
      tokens_to_add = elapsed_intervals * refill_rate
      new_tokens = min(bucket.tokens + tokens_to_add, capacity)
      last_refill = bucket.last_refill + elapsed_intervals * interval_ms
      %{tokens: new_tokens, last_refill: last_refill}
    else
      bucket
    end
  end
end

defmodule RateLimit.Middleware do
  @moduledoc """
  Plug middleware that enforces per-IP rate limiting using `RateLimit.TokenBucket`.
  Returns 429 Too Many Requests when the bucket is exhausted for the remote address.
  """

  @behaviour Plug

  alias RateLimit.TokenBucket
  import Plug.Conn

  @default_config %{capacity: 100, refill_rate: 10, refill_interval_ms: 1_000}

  @impl Plug
  def init(opts) do
    %{
      capacity: Keyword.get(opts, :capacity, @default_config.capacity),
      refill_rate: Keyword.get(opts, :refill_rate, @default_config.refill_rate),
      refill_interval_ms: Keyword.get(opts, :refill_interval_ms, @default_config.refill_interval_ms)
    }
  end

  @impl Plug
  def call(conn, config) do
    key = extract_client_key(conn)

    if TokenBucket.allow?(key, config) do
      conn
      |> put_resp_header("x-ratelimit-remaining", "#{TokenBucket.remaining(key, config)}")
    else
      conn
      |> put_resp_header("x-ratelimit-remaining", "0")
      |> send_resp(429, "Too Many Requests")
      |> halt()
    end
  end

  @spec extract_client_key(Plug.Conn.t()) :: String.t()
  defp extract_client_key(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
```
