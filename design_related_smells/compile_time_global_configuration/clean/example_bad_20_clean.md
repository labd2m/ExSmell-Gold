```elixir
defmodule Database.ConnectionPool do
  @moduledoc """
  Manages a fixed-size pool of database connections backed by a NimblePool
  worker pool. Provides checked-out connections for query execution and a
  convenience `with_connection/2` helper that automatically returns the
  connection after use.
  """

  use NimblePool

  require Logger

  @checkout_timeout_ms 5_000
  @idle_timeout_ms 60_000

  @pool_size Application.fetch_env!(:database, :pool_size)

  @type connection :: pid()
  @type query_result :: {:ok, term()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    NimblePool.start_link(
      __MODULE__,
      opts,
      pool_size: @pool_size,
      name: __MODULE__
    )
  end

  @doc """
  Checks out a connection from the pool and yields it to `fun`.
  The connection is automatically returned after `fun` completes,
  even if it raises.

  ## Parameters
    - `fun` - A one-arity function receiving the connection.
    - `opts` - Keyword list; `:timeout` overrides the default checkout timeout.
  """
  @spec with_connection((connection() -> term()), keyword()) :: term()
  def with_connection(fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout_ms)

    NimblePool.checkout!(
      __MODULE__,
      :checkout,
      fn _from, conn ->
        result = fun.(conn)
        {result, conn}
      end,
      timeout
    )
  end

  @doc """
  Checks out a connection, returning `{:ok, conn, pool_ref}` so the caller
  can manage the lifetime manually. Must be paired with `checkin/2`.

  ## Parameters
    - `opts` - Keyword list; `:timeout` overrides the checkout timeout.
  """
  @spec checkout(keyword()) :: {:ok, connection(), reference()} | {:error, :timeout}
  def checkout(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout_ms)

    try do
      NimblePool.checkout!(__MODULE__, :checkout, fn _from, conn ->
        {{:ok, conn}, conn}
      end, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Returns the current pool utilisation statistics.
  """
  @spec pool_stats() :: %{pool_size: pos_integer(), ready: non_neg_integer(), busy: non_neg_integer()}
  def pool_stats do
    {:ok, stats} = NimblePool.stats(__MODULE__)

    %{
      pool_size: @pool_size,
      ready: Map.get(stats, :ready, 0),
      busy: Map.get(stats, :busy, 0)
    }
  end

  # ---------------------------------------------------------------------------
  # NimblePool callbacks
  # ---------------------------------------------------------------------------

  @impl NimblePool
  def init_pool(_pool_state), do: {:ok, %{created: 0}}

  @impl NimblePool
  def init_worker(pool_state) do
    dsn = Application.fetch_env!(:database, :url)
    Logger.debug("Opening database connection pool_size=#{@pool_size}")

    case Postgrex.start_link(url: dsn, name: nil) do
      {:ok, conn} ->
        {:ok, conn, %{pool_state | created: pool_state.created + 1}}

      {:error, reason} ->
        Logger.error("Failed to open DB connection reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, conn, pool_state) do
    {:ok, conn, conn, pool_state}
  end

  @impl NimblePool
  def handle_checkin(conn, _from, _old_conn, pool_state) do
    {:ok, conn, pool_state}
  end

  @impl NimblePool
  def handle_info(:idle_timeout, _conn, pool_state) do
    Logger.debug("Idle connection timeout, recycling")
    {:remove, :idle_timeout, pool_state}
  end

  @impl NimblePool
  def handle_info(msg, conn, pool_state) do
    Logger.warning("Unexpected pool message: #{inspect(msg)}")
    {:ok, conn, pool_state}
  end

  @impl NimblePool
  def terminate_worker(reason, conn, pool_state) do
    Logger.debug("Terminating pool worker reason=#{inspect(reason)}")
    GenServer.stop(conn, :normal)
    {:ok, pool_state}
  end
end
```
