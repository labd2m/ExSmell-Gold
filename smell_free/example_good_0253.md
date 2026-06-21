```elixir
defmodule Traffic.RateLimiter do
  @moduledoc """
  A token-bucket rate limiter backed by a supervised GenServer.
  Each named bucket tracks a rolling request allowance that refills
  at a configurable rate. Callers receive `{:ok, remaining}` when
  capacity is available, or `{:error, :rate_limited}` when exhausted.
  """

  use GenServer

  alias Traffic.RateLimiter.Bucket

  @type bucket_name :: atom() | binary()
  @type limit_opts :: [capacity: pos_integer(), refill_rate: pos_integer(), window_ms: pos_integer()]

  @default_capacity 100
  @default_refill_rate 10
  @default_window_ms 1_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a `RateLimiter` process linked to the calling supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to consume `tokens` from the named bucket.
  Creates the bucket with default limits on first access.
  Returns `{:ok, remaining}` or `{:error, :rate_limited}`.
  """
  @spec check(bucket_name(), pos_integer(), limit_opts()) ::
          {:ok, non_neg_integer()} | {:error, :rate_limited}
  def check(bucket_name, tokens \\ 1, opts \\ [])
      when (is_atom(bucket_name) or is_binary(bucket_name)) and is_integer(tokens) and tokens > 0 do
    GenServer.call(__MODULE__, {:check, bucket_name, tokens, opts})
  end

  @doc """
  Resets the named bucket, restoring it to full capacity.
  """
  @spec reset(bucket_name()) :: :ok
  def reset(bucket_name) when is_atom(bucket_name) or is_binary(bucket_name) do
    GenServer.cast(__MODULE__, {:reset, bucket_name})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok, %{buckets: %{}}}
  end

  @impl GenServer
  def handle_call({:check, name, tokens, opts}, _from, state) do
    {bucket, state} = fetch_or_create_bucket(state, name, opts)
    refilled = refill(bucket)

    case consume(refilled, tokens) do
      {:ok, updated} ->
        new_state = put_bucket(state, name, updated)
        {:reply, {:ok, updated.tokens}, new_state}

      :insufficient ->
        new_state = put_bucket(state, name, refilled)
        {:reply, {:error, :rate_limited}, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:reset, name}, state) do
    new_state = Map.update(state, :buckets, %{}, &Map.delete(&1, name))
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_or_create_bucket(state, name, opts) do
    case Map.get(state.buckets, name) do
      nil ->
        bucket = build_bucket(opts)
        {bucket, put_bucket(state, name, bucket)}

      existing ->
        {existing, state}
    end
  end

  defp build_bucket(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    %Bucket{
      capacity: capacity,
      tokens: capacity,
      refill_rate: Keyword.get(opts, :refill_rate, @default_refill_rate),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      last_refill_at: System.monotonic_time(:millisecond)
    }
  end

  defp refill(%Bucket{} = bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed_windows = div(now - bucket.last_refill_at, bucket.window_ms)
    added = elapsed_windows * bucket.refill_rate
    new_tokens = min(bucket.capacity, bucket.tokens + added)
    last_refill_at = bucket.last_refill_at + elapsed_windows * bucket.window_ms
    %Bucket{bucket | tokens: new_tokens, last_refill_at: last_refill_at}
  end

  defp consume(%Bucket{tokens: available} = bucket, requested) when available >= requested do
    {:ok, %Bucket{bucket | tokens: available - requested}}
  end

  defp consume(_bucket, _requested), do: :insufficient

  defp put_bucket(state, name, bucket) do
    %{state | buckets: Map.put(state.buckets, name, bucket)}
  end
end

defmodule Traffic.RateLimiter.Bucket do
  @moduledoc false

  @enforce_keys [:capacity, :tokens, :refill_rate, :window_ms, :last_refill_at]
  defstruct [:capacity, :tokens, :refill_rate, :window_ms, :last_refill_at]

  @type t :: %__MODULE__{
          capacity: pos_integer(),
          tokens: non_neg_integer(),
          refill_rate: pos_integer(),
          window_ms: pos_integer(),
          last_refill_at: integer()
        }
end
```
