```elixir
defmodule RateLimiter.TokenBucket do
  @moduledoc """
  GenServer-backed token bucket rate limiter for API request throttling.

  Each bucket is identified by a client key (e.g., API key or IP address).
  Buckets are lazily initialized, refilled at a configurable rate, and
  stored in ETS for concurrent read access.
  """

  use GenServer

  @table :rate_limit_buckets
  @refill_interval_ms 1_000

  @type client_key :: String.t()
  @type bucket_config :: %{capacity: pos_integer(), refill_rate: pos_integer()}

  @doc """
  Starts the rate limiter as a named linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume one token from the given client's bucket.

  Returns `:ok` if a token is available, or `{:error, :rate_limited}` when
  the bucket is exhausted.
  """
  @spec consume(client_key(), bucket_config()) :: :ok | {:error, :rate_limited}
  def consume(client_key, config) when is_binary(client_key) do
    GenServer.call(__MODULE__, {:consume, client_key, config})
  end

  @doc """
  Returns the current token count for a client bucket, or `nil` if not yet initialized.
  """
  @spec token_count(client_key()) :: non_neg_integer() | nil
  def token_count(client_key) when is_binary(client_key) do
    case :ets.lookup(@table, client_key) do
      [{^client_key, tokens, _last_refill}] -> tokens
      [] -> nil
    end
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    schedule_refill()
    {:ok, %{default_capacity: Keyword.get(opts, :default_capacity, 100)}}
  end

  @impl GenServer
  def handle_call({:consume, client_key, config}, _from, state) do
    now = System.monotonic_time(:millisecond)
    result = perform_consume(client_key, config, now)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:refill_buckets, state) do
    refill_all_buckets()
    schedule_refill()
    {:noreply, state}
  end

  defp perform_consume(client_key, %{capacity: capacity} = config, now) do
    case :ets.lookup(@table, client_key) do
      [] ->
        :ets.insert(@table, {client_key, capacity - 1, now})
        :ok

      [{^client_key, 0, _last_refill}] ->
        {:error, :rate_limited}

      [{^client_key, tokens, last_refill}] ->
        refilled = calculate_refill(tokens, config, now - last_refill)
        new_tokens = min(refilled - 1, capacity)
        :ets.insert(@table, {client_key, new_tokens, now})
        :ok
    end
  end

  defp calculate_refill(tokens, %{refill_rate: rate, capacity: capacity}, elapsed_ms) do
    added = trunc(elapsed_ms / 1_000 * rate)
    min(tokens + added, capacity)
  end

  defp refill_all_buckets do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.each(fn {key, tokens, last_refill} ->
      elapsed = now - last_refill

      if elapsed >= @refill_interval_ms do
        :ets.insert(@table, {key, tokens, now})
      end
    end)
  end

  defp schedule_refill do
    Process.send_after(self(), :refill_buckets, @refill_interval_ms)
  end
end
```
