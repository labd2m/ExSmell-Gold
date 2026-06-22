```elixir
defmodule Memoize do
  @moduledoc """
  A process-level memoization utility for deterministic, expensive computations.
  Results are cached in the calling process's dictionary keyed by a hash of
  the function name and arguments. An optional TTL evicts cached entries after
  a configurable number of seconds so long-lived processes do not serve stale
  results indefinitely. Suitable for per-request caches in Phoenix controllers
  or LiveViews where the calling process is short-lived enough that process
  dictionary growth is bounded.
  """

  @type cache_opts :: [ttl_seconds: pos_integer() | :infinity]

  @doc """
  Returns the cached result of `key` if fresh, otherwise evaluates `fun`,
  caches the result, and returns it. `key` must be a unique, comparable term.

  ## Example

      def expensive_query(user_id) do
        Memoize.cache({:user_stats, user_id}, fn ->
          Stats.compute_for(user_id)
        end, ttl_seconds: 30)
      end
  """
  @spec cache(term(), (() -> term()), cache_opts()) :: term()
  def cache(key, fun, opts \\ []) when is_function(fun, 0) do
    ttl = Keyword.get(opts, :ttl_seconds, :infinity)
    cache_key = {:memoize, :erlang.phash2(key)}
    now = System.monotonic_time(:second)

    case Process.get(cache_key) do
      {value, expires_at} when expires_at == :infinity or now < expires_at ->
        value

      _ ->
        value = fun.()
        expires_at = if ttl == :infinity, do: :infinity, else: now + ttl
        Process.put(cache_key, {value, expires_at})
        value
    end
  end

  @doc """
  Explicitly clears the cached value for `key` in the calling process.
  """
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    cache_key = {:memoize, :erlang.phash2(key)}
    Process.delete(cache_key)
    :ok
  end

  @doc """
  Clears all memoized entries from the calling process's dictionary.
  """
  @spec clear_all() :: non_neg_integer()
  def clear_all do
    keys =
      Process.get_keys()
      |> Enum.filter(&match?({:memoize, _}, &1))

    Enum.each(keys, &Process.delete/1)
    length(keys)
  end

  @doc """
  Returns the number of cache entries currently held in the calling process.
  """
  @spec size() :: non_neg_integer()
  def size do
    Process.get_keys()
    |> Enum.count(&match?({:memoize, _}, &1))
  end
end

defmodule Memoize.RequestCache do
  @moduledoc """
  A Plug that clears all process-level memoized entries after each request,
  preventing cross-request data leakage. Add to the router pipeline after
  other plugs to ensure caches are always invalidated on request completion.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      cleared = Memoize.clear_all()

      if cleared > 0 do
        require Logger
        Logger.debug("Request memoize cache cleared", entries_cleared: cleared)
      end

      conn
    end)
  end
end

defmodule Memoize.Supervisor do
  @moduledoc """
  Optional module-level memoization backed by a supervised ETS table with
  TTL eviction. Suitable for cross-process shared caches where the result is
  identical for all callers. Uses the same interface as the process-level
  `Memoize` module.
  """

  use GenServer

  @table :memoize_shared
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetches from shared ETS cache or evaluates and stores the result."
  @spec cache(term(), (() -> term()), Memoize.cache_opts()) :: term()
  def cache(key, fun, opts \\ []) when is_function(fun, 0) do
    ttl = Keyword.get(opts, :ttl_seconds, 300)
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when now < expires_at ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, value, now + ttl})
        value
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
