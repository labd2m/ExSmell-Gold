# File: `example_good_04.md`

```elixir
defmodule Notifications.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for controlling notification dispatch frequency
  per recipient identifier.

  Each recipient gets an independent bucket that refills at a configured
  rate. Stale buckets for inactive recipients are pruned periodically to
  prevent unbounded memory growth.
  """

  use GenServer

  @default_capacity 10
  @default_refill_rate 1
  @default_refill_interval_ms 1_000
  @cleanup_interval_ms 300_000

  @type recipient_id :: String.t()

  @type bucket :: %{
          tokens: non_neg_integer(),
          last_refill_ms: integer()
        }

  @type opts :: [
          capacity: pos_integer(),
          refill_rate: pos_integer(),
          refill_interval_ms: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume one token from the recipient's bucket.

  Returns `:allow` when a token was available and consumed,
  `:deny` when the bucket is empty.
  """
  @spec check(recipient_id()) :: :allow | :deny
  def check(recipient_id) when is_binary(recipient_id) do
    GenServer.call(__MODULE__, {:check, recipient_id})
  end

  @doc """
  Returns the current token count for a recipient's bucket.

  Returns `{:ok, count}` or `{:error, :unknown_recipient}`.
  """
  @spec tokens_remaining(recipient_id()) ::
          {:ok, non_neg_integer()} | {:error, :unknown_recipient}
  def tokens_remaining(recipient_id) when is_binary(recipient_id) do
    GenServer.call(__MODULE__, {:tokens_remaining, recipient_id})
  end

  @doc """
  Resets the bucket for a recipient back to full capacity.
  """
  @spec reset(recipient_id()) :: :ok
  def reset(recipient_id) when is_binary(recipient_id) do
    GenServer.cast(__MODULE__, {:reset, recipient_id})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      buckets: %{},
      capacity: Keyword.get(opts, :capacity, @default_capacity),
      refill_rate: Keyword.get(opts, :refill_rate, @default_refill_rate),
      refill_interval_ms: Keyword.get(opts, :refill_interval_ms, @default_refill_interval_ms)
    }

    schedule_cleanup()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, recipient_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    bucket = get_or_create_bucket(state, recipient_id, now)
    refilled = refill_bucket(bucket, state, now)
    {decision, updated_bucket} = consume_token(refilled)
    new_state = put_in(state, [:buckets, recipient_id], updated_bucket)
    {:reply, decision, new_state}
  end

  @impl GenServer
  def handle_call({:tokens_remaining, recipient_id}, _from, state) do
    result =
      case Map.fetch(state.buckets, recipient_id) do
        {:ok, bucket} -> {:ok, bucket.tokens}
        :error -> {:error, :unknown_recipient}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:reset, recipient_id}, state) do
    now = System.monotonic_time(:millisecond)
    full_bucket = %{tokens: state.capacity, last_refill_ms: now}
    {:noreply, put_in(state, [:buckets, recipient_id], full_bucket)}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cutoff_ms = System.monotonic_time(:millisecond) - @cleanup_interval_ms

    active =
      Map.reject(state.buckets, fn {_id, bucket} ->
        bucket.last_refill_ms < cutoff_ms
      end)

    schedule_cleanup()
    {:noreply, %{state | buckets: active}}
  end

  defp get_or_create_bucket(state, recipient_id, now) do
    Map.get(state.buckets, recipient_id, %{tokens: state.capacity, last_refill_ms: now})
  end

  defp refill_bucket(%{tokens: tokens, last_refill_ms: last} = bucket, state, now) do
    intervals_elapsed = div(now - last, state.refill_interval_ms)
    added_tokens = intervals_elapsed * state.refill_rate
    new_tokens = min(tokens + added_tokens, state.capacity)
    new_last = last + intervals_elapsed * state.refill_interval_ms
    %{bucket | tokens: new_tokens, last_refill_ms: new_last}
  end

  defp consume_token(%{tokens: 0} = bucket), do: {:deny, bucket}
  defp consume_token(%{tokens: n} = bucket), do: {:allow, %{bucket | tokens: n - 1}}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
