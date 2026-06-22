```elixir
defmodule Http.ConnectionPool do
  @moduledoc """
  A `NimblePool`-backed HTTP connection pool that reuses persistent TCP
  connections to a single upstream host. Reusing connections eliminates
  per-request TLS handshake overhead for high-frequency service-to-service
  calls. The pool lazy-opens connections on first use, enforces a configurable
  maximum, and returns idle connections to the pool or closes them when they
  are detected to be stale.
  """

  @behaviour NimblePool

  require Logger

  @type pool_opts :: [
          host: binary(),
          port: pos_integer(),
          scheme: :http | :https,
          pool_size: pos_integer(),
          checkout_timeout_ms: pos_integer()
        ]

  @default_pool_size 10
  @default_checkout_timeout_ms 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(pool_opts()) :: GenServer.on_start()
  def start_link(opts) do
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    name = Keyword.get(opts, :name, __MODULE__)

    NimblePool.start_link(
      worker: {__MODULE__, opts},
      pool_size: pool_size,
      name: name
    )
  end

  @doc """
  Executes `fun` with a checked-out HTTP connection from the pool.
  `fun` receives `{conn, pool}` and must return `{result, conn | :close}`.
  Returning `:close` signals the pool to discard the connection.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec request(atom() | pid(), (Mint.HTTP.t() -> {term(), Mint.HTTP.t() | :close}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(pool \\ __MODULE__, fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :checkout_timeout_ms, @default_checkout_timeout_ms)

    NimblePool.checkout!(pool, :checkout, fn _from, conn ->
      {result, next_conn} = fun.(conn)
      {result, next_conn}
    end, timeout)
  rescue
    e in NimblePool.PoolTimeoutError ->
      {:error, {:pool_timeout, e.message}}
  end

  # ---------------------------------------------------------------------------
  # NimblePool callbacks
  # ---------------------------------------------------------------------------

  @impl NimblePool
  def init_worker(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, 443)
    scheme = Keyword.get(opts, :scheme, :https)

    case Mint.HTTP.connect(scheme, host, port) do
      {:ok, conn} ->
        Logger.debug("HTTP pool connection opened", host: host, port: port)
        {:ok, conn, opts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, conn, pool_state) do
    {:ok, conn, conn, pool_state}
  end

  @impl NimblePool
  def handle_checkin(:close, _from, _conn, pool_state) do
    {:remove, :closed, pool_state}
  end

  def handle_checkin(conn, _from, _old_conn, pool_state) do
    if Mint.HTTP.open?(conn) do
      {:ok, conn, pool_state}
    else
      {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, _responses} -> {:ok, conn}
      {:error, _conn, _reason, _responses} -> {:remove, :error}
      :unknown -> {:ok, conn}
    end
  end

  @impl NimblePool
  def terminate_worker(reason, conn, _pool_state) do
    Logger.debug("HTTP pool connection closed", reason: inspect(reason))
    Mint.HTTP.close(conn)
    :ok
  end
end
```
