```elixir
defmodule Gateway.RateLimiter do
  @moduledoc """
  A token-bucket rate limiter backed by a named GenServer.

  Each named bucket is registered with a capacity and a refill rate.
  Tokens are consumed per request and replenished on a configurable schedule.
  The limiter is designed to be started under a supervision tree.
  """

  use GenServer

  require Logger

  @type bucket_name :: atom() | String.t()
  @type bucket_config :: %{
          capacity: pos_integer(),
          refill_rate: pos_integer(),
          refill_interval_ms: pos_integer()
        }
  @type consume_result :: {:ok, non_neg_integer()} | {:error, :rate_limited | :unknown_bucket}

  @default_capacity 100
  @default_refill_rate 10
  @default_refill_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a named bucket with the provided configuration.
  Missing config keys fall back to defaults.
  """
  @spec register(bucket_name(), map()) :: :ok
  def register(name, config \\ %{}) do
    GenServer.cast(__MODULE__, {:register, name, normalize(config)})
  end

  @doc """
  Attempts to consume `tokens` from the named bucket.
  Returns `{:ok, remaining}` on success or `{:error, reason}` on failure.
  """
  @spec consume(bucket_name(), pos_integer()) :: consume_result()
  def consume(name, tokens \\ 1) when is_integer(tokens) and tokens > 0 do
    GenServer.call(__MODULE__, {:consume, name, tokens})
  end

  @doc "Returns a map of all registered buckets and their current state."
  @spec buckets() :: map()
  def buckets, do: GenServer.call(__MODULE__, :buckets)

  @impl GenServer
  def init(_opts) do
    schedule_refill(@default_refill_interval_ms)
    {:ok, %{buckets: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, name, config}, state) do
    bucket = Map.put(config, :tokens, config.capacity)
    {:noreply, put_in(state, [:buckets, name], bucket)}
  end

  @impl GenServer
  def handle_call({:consume, name, tokens}, _from, state) do
    {reply, new_state} = attempt_consume(state, name, tokens)
    {:reply, reply, new_state}
  end

  @impl GenServer
  def handle_call(:buckets, _from, state) do
    {:reply, state.buckets, state}
  end

  @impl GenServer
  def handle_info(:refill, state) do
    schedule_refill(@default_refill_interval_ms)
    {:noreply, %{state | buckets: refill_all(state.buckets)}}
  end

  defp attempt_consume(state, name, requested) do
    case Map.get(state.buckets, name) do
      nil ->
        {{:error, :unknown_bucket}, state}

      %{tokens: available} when available >= requested ->
        new_state = update_in(state, [:buckets, name, :tokens], &(&1 - requested))
        {{:ok, available - requested}, new_state}

      _ ->
        {{:error, :rate_limited}, state}
    end
  end

  defp refill_all(buckets) do
    Map.new(buckets, fn {name, bucket} -> {name, refill_bucket(bucket)} end)
  end

  defp refill_bucket(%{tokens: current, capacity: cap, refill_rate: rate} = bucket) do
    %{bucket | tokens: min(current + rate, cap)}
  end

  defp schedule_refill(interval), do: Process.send_after(self(), :refill, interval)

  defp normalize(config) do
    %{
      capacity: Map.get(config, :capacity, @default_capacity),
      refill_rate: Map.get(config, :refill_rate, @default_refill_rate),
      refill_interval_ms: Map.get(config, :refill_interval_ms, @default_refill_interval_ms)
    }
  end
end
```
