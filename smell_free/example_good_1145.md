```elixir
defmodule Gateway.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for API gateway request throttling.

  Each caller receives an isolated bucket that refills at a fixed rate per
  second. The limiter is started under a supervision tree and accessed via
  its registered name. Bucket state is held entirely inside the GenServer
  to avoid cross-process sharing of large data structures.
  """
  use GenServer

  require Logger

  @type caller_id :: String.t()
  @type bucket :: non_neg_integer()
  @type state :: %{
          buckets: %{optional(caller_id()) => bucket()},
          capacity: pos_integer(),
          refill_rate: pos_integer()
        }

  @default_capacity 60
  @default_refill_rate 10
  @refill_interval_ms 1_000

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Starts the rate limiter linked to the calling supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume one request token for `caller_id`.

  Returns `{:ok, :allowed}` when a token is available or
  `{:error, :rate_limited}` when the caller's bucket is exhausted.
  """
  @spec check_rate(caller_id()) :: {:ok, :allowed} | {:error, :rate_limited}
  def check_rate(caller_id) when is_binary(caller_id) do
    GenServer.call(__MODULE__, {:check_rate, caller_id})
  end

  @doc "Returns the current token count for a known caller bucket."
  @spec bucket_tokens(caller_id()) :: {:ok, non_neg_integer()} | {:error, :unknown_caller}
  def bucket_tokens(caller_id) when is_binary(caller_id) do
    GenServer.call(__MODULE__, {:bucket_tokens, caller_id})
  end

  @doc "Resets the token bucket for `caller_id` to the configured capacity."
  @spec reset(caller_id()) :: :ok
  def reset(caller_id) when is_binary(caller_id) do
    GenServer.cast(__MODULE__, {:reset, caller_id})
  end

  # ── Server callbacks ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    refill_rate = Keyword.get(opts, :refill_rate, @default_refill_rate)
    schedule_refill()
    {:ok, %{buckets: %{}, capacity: capacity, refill_rate: refill_rate}}
  end

  @impl GenServer
  def handle_call({:check_rate, caller_id}, _from, state) do
    {reply, new_state} = consume_token(caller_id, state)
    {:reply, reply, new_state}
  end

  def handle_call({:bucket_tokens, caller_id}, _from, state) do
    reply = fetch_token_count(caller_id, state.buckets)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:reset, caller_id}, state) do
    updated = Map.put(state.buckets, caller_id, state.capacity)
    {:noreply, %{state | buckets: updated}}
  end

  @impl GenServer
  def handle_info(:refill_buckets, state) do
    schedule_refill()
    {:noreply, apply_refill(state)}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp consume_token(caller_id, state) do
    current = Map.get(state.buckets, caller_id, state.capacity)

    if current > 0 do
      updated = Map.put(state.buckets, caller_id, current - 1)
      {{:ok, :allowed}, %{state | buckets: updated}}
    else
      {{:error, :rate_limited}, state}
    end
  end

  defp fetch_token_count(caller_id, buckets) do
    case Map.fetch(buckets, caller_id) do
      {:ok, count} -> {:ok, count}
      :error -> {:error, :unknown_caller}
    end
  end

  defp apply_refill(state) do
    refilled =
      Map.new(state.buckets, fn {id, tokens} ->
        {id, min(tokens + state.refill_rate, state.capacity)}
      end)

    %{state | buckets: refilled}
  end

  defp schedule_refill do
    Process.send_after(self(), :refill_buckets, @refill_interval_ms)
  end
end
```
