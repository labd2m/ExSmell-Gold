```elixir
defmodule Gateway.RequestThrottler do
  @moduledoc """
  Token-bucket rate limiter implemented as a GenServer for controlling
  inbound request throughput per client key.

  Each client key maintains its own independent bucket. Buckets refill
  at a steady rate and cap at a configured maximum burst size.
  This module is designed for low-latency in-path checks.
  """

  use GenServer

  @type client_key :: String.t()
  @type bucket :: %{tokens: float(), last_refill: integer()}
  @type state :: %{
          buckets: %{client_key() => bucket()},
          refill_rate: float(),
          burst_limit: non_neg_integer()
        }

  @default_refill_rate 10.0
  @default_burst_limit 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Attempts to consume `n` tokens from the client's bucket.

  Returns `:allow` if sufficient tokens exist, or `{:deny, retry_after_ms}`
  indicating how long the client should wait before retrying.
  """
  @spec check(client_key(), pos_integer()) :: :allow | {:deny, non_neg_integer()}
  def check(client_key, tokens \\ 1)
      when is_binary(client_key) and is_integer(tokens) and tokens > 0 do
    GenServer.call(__MODULE__, {:check, client_key, tokens})
  end

  @doc "Removes the bucket state for a given client key."
  @spec clear(client_key()) :: :ok
  def clear(client_key) when is_binary(client_key) do
    GenServer.cast(__MODULE__, {:clear, client_key})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      buckets: %{},
      refill_rate: Keyword.get(opts, :refill_rate, @default_refill_rate),
      burst_limit: Keyword.get(opts, :burst_limit, @default_burst_limit)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, client_key, tokens}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    bucket = get_or_init_bucket(state.buckets, client_key, state.burst_limit, now_ms)
    refilled = refill_bucket(bucket, now_ms, state.refill_rate, state.burst_limit)

    if refilled.tokens >= tokens do
      updated_bucket = %{refilled | tokens: refilled.tokens - tokens}
      updated_buckets = Map.put(state.buckets, client_key, updated_bucket)
      {:reply, :allow, %{state | buckets: updated_buckets}}
    else
      deficit = tokens - refilled.tokens
      retry_after_ms = ceil(deficit / state.refill_rate * 1000)
      {:reply, {:deny, retry_after_ms}, %{state | buckets: Map.put(state.buckets, client_key, refilled)}}
    end
  end

  @impl GenServer
  def handle_cast({:clear, client_key}, state) do
    {:noreply, %{state | buckets: Map.delete(state.buckets, client_key)}}
  end

  @spec get_or_init_bucket(%{client_key() => bucket()}, client_key(), non_neg_integer(), integer()) :: bucket()
  defp get_or_init_bucket(buckets, client_key, burst_limit, now_ms) do
    Map.get_lazy(buckets, client_key, fn ->
      %{tokens: burst_limit * 1.0, last_refill: now_ms}
    end)
  end

  @spec refill_bucket(bucket(), integer(), float(), non_neg_integer()) :: bucket()
  defp refill_bucket(%{tokens: tokens, last_refill: last_refill}, now_ms, refill_rate, burst_limit) do
    elapsed_seconds = (now_ms - last_refill) / 1000.0
    new_tokens = min(burst_limit * 1.0, tokens + elapsed_seconds * refill_rate)
    %{tokens: new_tokens, last_refill: now_ms}
  end
end
```
