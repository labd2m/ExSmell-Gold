```elixir
# ── file: lib/rate_limiter/policy.ex ────────────────────────────────────────


defmodule RateLimiter.Policy do
  @moduledoc """
  Token-bucket rate limiter with configurable policies per endpoint/resource.
  Defined in `lib/rate_limiter/policy.ex`.
  """

  alias RateLimiter.{BucketStore, PolicyRegistry}

  @type key :: String.t()
  @type policy_name :: atom()

  @type bucket_state :: %{
    key: key(),
    policy: policy_name(),
    tokens: float(),
    capacity: pos_integer(),
    refill_rate: float(),
    last_refill_at: integer()
  }

  @doc """
  Check whether a request is allowed without consuming a token.
  Returns `:allow` or `{:deny, retry_after_ms}`.
  """
  @spec check(policy_name(), key(), pos_integer()) ::
          :allow | {:deny, non_neg_integer()}
  def check(policy_name, key, cost \\ 1) do
    with {:ok, policy} <- PolicyRegistry.fetch(policy_name),
         {:ok, bucket} <- get_or_init(policy_name, key, policy) do
      refilled = refill(bucket)

      if refilled.tokens >= cost do
        :allow
      else
        wait_ms = ceil((cost - refilled.tokens) / policy.refill_rate * 1000)
        {:deny, wait_ms}
      end
    else
      {:error, reason} -> {:deny, 0}
    end
  end

  @doc "Check and consume tokens atomically. Returns `:ok` or `{:error, :rate_limited}`."
  @spec consume(policy_name(), key(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def consume(policy_name, key, cost \\ 1) do
    with {:ok, policy} <- PolicyRegistry.fetch(policy_name),
         {:ok, bucket} <- get_or_init(policy_name, key, policy) do
      refilled = refill(bucket)

      if refilled.tokens >= cost do
        updated = %{refilled | tokens: refilled.tokens - cost}
        BucketStore.put(bucket_key(policy_name, key), updated)
        :ok
      else
        {:error, :rate_limited}
      end
    else
      {:error, _} -> {:error, :rate_limited}
    end
  end

  @doc "Return the number of tokens remaining for a key under a policy."
  @spec remaining(policy_name(), key()) :: {:ok, float()} | {:error, String.t()}
  def remaining(policy_name, key) do
    with {:ok, policy} <- PolicyRegistry.fetch(policy_name),
         {:ok, bucket} <- get_or_init(policy_name, key, policy) do
      refilled = refill(bucket)
      {:ok, Float.round(refilled.tokens, 2)}
    end
  end

  @doc "Reset the token bucket for a key back to full capacity."
  @spec reset(policy_name(), key()) :: :ok | {:error, String.t()}
  def reset(policy_name, key) do
    with {:ok, policy} <- PolicyRegistry.fetch(policy_name) do
      full_bucket = %{
        key: key,
        policy: policy_name,
        tokens: policy.capacity * 1.0,
        capacity: policy.capacity,
        refill_rate: policy.refill_rate,
        last_refill_at: System.monotonic_time(:millisecond)
      }

      BucketStore.put(bucket_key(policy_name, key), full_bucket)
    end
  end

  @doc "Return the UTC datetime at which the bucket will be full again."
  @spec block_until(policy_name(), key()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def block_until(policy_name, key) do
    with {:ok, policy} <- PolicyRegistry.fetch(policy_name),
         {:ok, bucket} <- get_or_init(policy_name, key, policy) do
      refilled = refill(bucket)
      deficit = max(policy.capacity - refilled.tokens, 0)
      ms_to_full = ceil(deficit / policy.refill_rate * 1000)
      full_at = DateTime.add(DateTime.utc_now(), ms_to_full, :millisecond)
      {:ok, full_at}
    end
  end

  defp get_or_init(policy_name, key, policy) do
    bkey = bucket_key(policy_name, key)

    case BucketStore.get(bkey) do
      {:ok, bucket} ->
        {:ok, bucket}

      :miss ->
        new_bucket = %{
          key: key,
          policy: policy_name,
          tokens: policy.capacity * 1.0,
          capacity: policy.capacity,
          refill_rate: policy.refill_rate,
          last_refill_at: System.monotonic_time(:millisecond)
        }

        BucketStore.put(bkey, new_bucket)
        {:ok, new_bucket}
    end
  end

  defp refill(%{tokens: t, capacity: cap, refill_rate: rate, last_refill_at: last} = bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed_s = (now - last) / 1000.0
    new_tokens = min(t + elapsed_s * rate, cap * 1.0)
    %{bucket | tokens: new_tokens, last_refill_at: now}
  end

  defp bucket_key(policy_name, key), do: "rl:#{policy_name}:#{key}"
end


# ── file: lib/rate_limiter/policy_admin.ex ─────────────────────────────────────────────────────


defmodule RateLimiter.Policy do
  @moduledoc """
  Admin tooling for inspecting and managing rate limit policies at runtime.
  """

  alias RateLimiter.{BucketStore, PolicyRegistry}

  @doc "List all registered policies and their configuration."
  @spec list_policies() :: [map()]
  def list_policies do
    PolicyRegistry.all()
    |> Enum.map(fn {name, policy} ->
      Map.put(policy, :name, name)
    end)
  end

  @doc "Register a new rate limiting policy at runtime."
  @spec register_policy(atom(), map()) :: :ok | {:error, String.t()}
  def register_policy(name, %{capacity: cap, refill_rate: rate} = config)
      when is_integer(cap) and cap > 0 and is_float(rate) and rate > 0 do
    PolicyRegistry.put(name, config)
  end

  def register_policy(_name, _config) do
    {:error, "Policy config must include positive integer capacity and float refill_rate"}
  end

  @doc "Bulk-reset all buckets for a given policy (e.g., after an incident)."
  @spec bulk_reset(atom()) :: {:ok, non_neg_integer()}
  def bulk_reset(policy_name) do
    prefix = "rl:#{policy_name}:"
    keys = BucketStore.keys_with_prefix(prefix)
    Enum.each(keys, &BucketStore.delete/1)
    {:ok, length(keys)}
  end

  @doc "Return utilisation statistics for all active buckets of a policy."
  @spec utilisation(atom()) :: [map()]
  def utilisation(policy_name) do
    prefix = "rl:#{policy_name}:"

    BucketStore.keys_with_prefix(prefix)
    |> Enum.map(fn bkey ->
      {:ok, bucket} = BucketStore.get(bkey)
      pct = Float.round((1 - bucket.tokens / bucket.capacity) * 100, 1)
      %{key: bucket.key, used_pct: pct, tokens_remaining: bucket.tokens}
    end)
    |> Enum.sort_by(& &1.used_pct, :desc)
  end
end

```
