# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `RateLimiting.Bucket.consume/3`
- **Affected function(s):** `RateLimiting.Bucket.consume/3` (library side); `RateLimiting.ApiGateway.check_and_forward/3` (client side)
- **Explanation:** `consume/3` raises `RuntimeError` when a client has exceeded its rate limit or when the requested token count is invalid. A rate-limit breach is a predictable, frequent occurrence in any API gateway — not a system exception. Callers must use `try/rescue` to distinguish a throttled request from an allowed one, which is fundamental control-flow, not exceptional handling.

```elixir
defmodule RateLimiting.Policy do
  @moduledoc "Defines rate-limit policies by client tier."

  @policies %{
    :free => %{requests_per_minute: 30, burst_allowance: 5},
    :standard => %{requests_per_minute: 300, burst_allowance: 30},
    :premium => %{requests_per_minute: 3000, burst_allowance: 150},
    :internal => %{requests_per_minute: 100_000, burst_allowance: 1000}
  }

  def for_tier(tier), do: Map.fetch(@policies, tier)
  def tiers, do: Map.keys(@policies)
end

defmodule RateLimiting.TokenBucketState do
  @moduledoc "Mutable state for a single token bucket."

  defstruct [:client_id, :capacity, :tokens, :last_refill_at, :tier]
end

defmodule RateLimiting.BucketStore do
  @moduledoc "Agent-backed store of token bucket states per client."

  use Agent

  alias RateLimiting.{Policy, TokenBucketState}

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get_or_create(client_id, tier) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state, client_id) do
        {:ok, bucket} ->
          {bucket, state}

        :error ->
          {:ok, policy} = Policy.for_tier(tier)
          cap = policy.requests_per_minute + policy.burst_allowance

          bucket = %TokenBucketState{
            client_id: client_id,
            capacity: cap,
            tokens: cap,
            last_refill_at: System.monotonic_time(:millisecond),
            tier: tier
          }

          {bucket, Map.put(state, client_id, bucket)}
      end
    end)
  end

  def update(client_id, new_state) do
    Agent.update(__MODULE__, &Map.put(&1, client_id, new_state))
  end
end

defmodule RateLimiting.Bucket do
  @moduledoc """
  Implements a token-bucket rate limiter with configurable tier policies.
  Used by the API gateway to enforce per-client request quotas.
  """

  alias RateLimiting.{BucketStore, Policy}
  require Logger

  @refill_interval_ms 60_000

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `consume/3` raises RuntimeError for two
  # VALIDATION: expected conditions: an invalid token count and a rate-limit breach.
  # VALIDATION: A rate limit being exceeded is one of the most common, predictable
  # VALIDATION: events in a gateway. Callers routing API requests cannot use a
  # VALIDATION: simple conditional — they must catch the exception just to decide
  # VALIDATION: whether to allow or reject a request, making try/rescue the only
  # VALIDATION: available control-flow mechanism.
  def consume(client_id, tier, tokens \\ 1) do
    unless is_integer(tokens) and tokens > 0 do
      raise RuntimeError,
        message: "Token count must be a positive integer, got: #{inspect(tokens)}"
    end

    {:ok, policy} = Policy.for_tier(tier)

    bucket = BucketStore.get_or_create(client_id, tier)
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - bucket.last_refill_at

    refill =
      if elapsed_ms >= @refill_interval_ms do
        policy.requests_per_minute
      else
        trunc(policy.requests_per_minute * elapsed_ms / @refill_interval_ms)
      end

    available = min(bucket.capacity, bucket.tokens + refill)

    if available < tokens do
      Logger.warning("Rate limit exceeded for client=#{client_id} tier=#{tier}")

      raise RuntimeError,
        message:
          "Rate limit exceeded for client '#{client_id}' (tier: #{tier}). " <>
            "Available: #{available}, requested: #{tokens}. Retry after the next refill window."
    end

    updated = %{bucket | tokens: available - tokens, last_refill_at: now}
    BucketStore.update(client_id, updated)

    Logger.debug("Consumed #{tokens} token(s) for client=#{client_id}, remaining=#{updated.tokens}")
    %{client_id: client_id, tokens_remaining: updated.tokens, allowed: true}
  end
  # VALIDATION: SMELL END
end

defmodule RateLimiting.ApiGateway do
  @moduledoc """
  Entry point for rate-checked API requests. Enforces per-client limits
  before forwarding requests to the upstream handler.
  """

  alias RateLimiting.Bucket
  require Logger

  def check_and_forward(client_id, tier, request) do
    # Client forced to use try/rescue because Bucket.consume/3 raises on a
    # rate-limit breach instead of returning {:error, :rate_limited} | {:ok, info}.
    try do
      Bucket.consume(client_id, tier)

      Logger.info("Request forwarded for client=#{client_id} path=#{request.path}")
      {:ok, %{status: :forwarded, client_id: client_id, request: request}}
    rescue
      e in RuntimeError ->
        Logger.info("Request throttled for client=#{client_id}: #{e.message}")

        {:error,
         %{
           status: :rate_limited,
           client_id: client_id,
           reason: e.message,
           retry_after_seconds: 60
         }}
    end
  end
end
```
