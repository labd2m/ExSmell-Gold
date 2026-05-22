```elixir
defmodule Cache.LocalStore do
  @moduledoc """
  An in-process ETS-backed cache with configurable TTL.
  Entries are lazily evicted on read and proactively swept
  on a background timer. The default TTL is sourced from
  application configuration.
  """

  use GenServer

  require Logger

  @default_ttl_seconds Application.fetch_env!(:cache, :default_ttl_seconds)

  @sweep_interval_ms 30_000
  @table __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(term(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
    expires_at = System.monotonic_time(:second) + ttl
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [] ->
        :miss

      [{^key, _value, expires_at}] when expires_at < now ->
        :ets.delete(@table, key)
        :miss

      [{^key, value, _expires_at}] ->
        {:ok, value}
    end
  end

  @spec get_or_fetch(term(), keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def get_or_fetch(key, opts \\ [], fetch_fn) do
    case get(key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case fetch_fn.() do
          {:ok, value} ->
            put(key, value, opts)
            {:ok, value}

          {:error, _} = err ->
            Logger.warning("Cache miss and fetch failed", key: inspect(key))
            err
        end
    end
  end

  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    Logger.info("Cache flushed")
    :ok
  end

  @spec stats() :: %{size: non_neg_integer(), default_ttl: non_neg_integer()}
  def stats do
    %{
      size: :ets.info(@table, :size),
      default_ttl: @default_ttl_seconds
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    Logger.info("Cache started", default_ttl_seconds: @default_ttl_seconds)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    evict_expired()
    schedule_sweep()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp evict_expired do
    now = System.monotonic_time(:second)

    expired =
      :ets.foldl(
        fn {key, _val, expires_at}, acc ->
          if expires_at < now, do: [key | acc], else: acc
        end,
        [],
        @table
      )

    Enum.each(expired, &:ets.delete(@table, &1))

    if length(expired) > 0 do
      Logger.debug("Cache sweep evicted entries", count: length(expired))
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
