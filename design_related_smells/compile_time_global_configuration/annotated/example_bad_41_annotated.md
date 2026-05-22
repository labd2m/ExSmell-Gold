# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@pool_size` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `child_spec/1`, `start_link/1`
- **Explanation:** `Application.fetch_env!/2` is invoked at compile-time to read the pool size from the application environment. Because `:db` has not been loaded during compilation, Elixir raises an `ArgumentError` or emits a warning. The integer is frozen in the bytecode, so adjusting the pool size dynamically (e.g. in response to load) requires recompiling the module.

---

```elixir
defmodule Db.ConnectionPool do
  @moduledoc """
  Manages a pool of PostgreSQL database connections using Postgrex.
  Pool size, checkout timeout, and query timeout are configurable.
  This module is intended to be placed in a supervision tree.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is executed
  # VALIDATION: at compile-time while the module is being loaded by the Elixir
  # VALIDATION: compiler. The :db application has not been started, so Elixir
  # VALIDATION: raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :pool_size for application :db
  # VALIDATION: The pool size integer is also hardened into the .beam,
  # VALIDATION: preventing runtime tuning without recompilation.
  @pool_size Application.fetch_env!(:db, :pool_size)
  # VALIDATION: SMELL END

  @checkout_timeout_ms 5_000
  @query_timeout_ms 15_000
  @idle_interval_ms 1_000
  @max_restarts 5

  @type pool_opts :: %{
          optional(:name) => atom(),
          optional(:database) => String.t(),
          optional(:hostname) => String.t(),
          optional(:username) => String.t(),
          optional(:password) => String.t(),
          optional(:port) => pos_integer(),
          optional(:ssl) => boolean()
        }

  @spec child_spec(pool_opts()) :: Supervisor.child_spec()
  def child_spec(opts \\ %{}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(pool_opts()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ %{}) do
    db_config = build_config(opts)

    Logger.info("Starting DB connection pool",
      pool_size: @pool_size,
      hostname: db_config[:hostname],
      database: db_config[:database]
    )

    DBConnection.start_link(Postgrex.Protocol, db_config)
  end

  @spec query(String.t(), list(), keyword()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def query(sql, params \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @query_timeout_ms)
    pool = Keyword.get(opts, :pool, __MODULE__)

    case Postgrex.query(pool, sql, params, timeout: timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}} = err} ->
        Logger.error("Table not found during query", sql: sql, error: inspect(err))
        {:error, :table_not_found}

      {:error, %DBConnection.ConnectionError{} = err} ->
        Logger.error("DB connection error", sql: sql, error: inspect(err))
        {:error, :connection_error}

      {:error, reason} ->
        Logger.error("Query failed", sql: sql, reason: inspect(reason))
        {:error, reason}
    end
  end

  @spec transaction((DBConnection.t() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, @query_timeout_ms)
    pool = Keyword.get(opts, :pool, __MODULE__)

    Postgrex.transaction(pool, fun, timeout: timeout)
  end

  @spec checkout_timeout() :: non_neg_integer()
  def checkout_timeout, do: @checkout_timeout_ms

  @spec pool_size() :: pos_integer()
  def pool_size, do: @pool_size

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_config(opts) do
    env_config = Application.get_env(:db, :postgrex, [])

    defaults = [
      hostname: "localhost",
      port: 5432,
      database: "app_db",
      username: "postgres",
      password: "postgres",
      ssl: false,
      pool_size: @pool_size,
      pool: DBConnection.ConnectionPool,
      name: __MODULE__,
      checkout_timeout: @checkout_timeout_ms,
      idle_interval: @idle_interval_ms,
      max_restarts: @max_restarts
    ]

    opts_list = Enum.to_list(opts)
    Keyword.merge(defaults, Keyword.merge(env_config, opts_list))
  end
end
```
