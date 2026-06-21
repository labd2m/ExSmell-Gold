```elixir
defmodule Infrastructure.AdvisoryLock do
  @moduledoc """
  Provides distributed mutual exclusion using PostgreSQL advisory locks.
  Because advisory locks are connection-scoped, each acquisition checks out
  a dedicated connection from the pool, holds it for the duration of the
  critical section, and releases it when the caller's function returns.
  This guarantees lock release even when the caller raises an exception.

  Advisory locks are non-reentrant; callers must not nest calls to `with_lock/3`
  using the same `lock_key` on the same database connection.
  """

  alias Ecto.Adapters.SQL

  require Logger

  @type lock_key :: integer() | binary()
  @type lock_opts :: [timeout_ms: pos_integer()]

  @default_timeout_ms 5_000

  @doc """
  Acquires the advisory lock identified by `lock_key`, executes `fun`,
  then releases the lock. Returns `{:ok, result}` where `result` is the
  return value of `fun`, or `{:error, :lock_timeout}` when the lock cannot
  be acquired within `:timeout_ms` milliseconds.

  ## Example

      AdvisoryLock.with_lock("reconcile:account:#{account_id}", fn ->
        Ledger.reconcile(account_id)
      end)
  """
  @spec with_lock(lock_key(), (() -> term()), lock_opts()) ::
          {:ok, term()} | {:error, :lock_timeout | term()}
  def with_lock(lock_key, fun, opts \\ [])
      when (is_integer(lock_key) or is_binary(lock_key)) and is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    numeric_key = to_numeric_key(lock_key)

    MyApp.Repo.transaction(fn ->
      case acquire(numeric_key, timeout_ms) do
        :ok ->
          result = fun.()
          release(numeric_key)
          result

        {:error, :lock_timeout} ->
          MyApp.Repo.rollback(:lock_timeout)
      end
    end)
  end

  @doc """
  Returns `true` if the given `lock_key` is currently held by any session
  in the PostgreSQL cluster. Useful for diagnostic tooling only; do not
  use this to build conditional logic around locking.
  """
  @spec held?(lock_key()) :: boolean()
  def held?(lock_key) when is_integer(lock_key) or is_binary(lock_key) do
    numeric_key = to_numeric_key(lock_key)

    case SQL.query(MyApp.Repo, "SELECT pg_try_advisory_lock($1)", [numeric_key]) do
      {:ok, %{rows: [[true]]}} ->
        SQL.query!(MyApp.Repo, "SELECT pg_advisory_unlock($1)", [numeric_key])
        false

      {:ok, %{rows: [[false]]}} ->
        true

      {:error, _reason} ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp acquire(numeric_key, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    acquire_with_deadline(numeric_key, deadline)
  end

  defp acquire_with_deadline(numeric_key, deadline) do
    case SQL.query(MyApp.Repo, "SELECT pg_try_advisory_xact_lock($1)", [numeric_key]) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: [[false]]}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          acquire_with_deadline(numeric_key, deadline)
        else
          Logger.warning("Advisory lock acquisition timed out", lock_key: numeric_key)
          {:error, :lock_timeout}
        end

      {:error, reason} ->
        {:error, {:query_failed, reason}}
    end
  end

  defp release(numeric_key) do
    SQL.query!(MyApp.Repo, "SELECT pg_advisory_xact_unlock($1)", [numeric_key])
    :ok
  end

  defp to_numeric_key(key) when is_integer(key), do: key

  defp to_numeric_key(key) when is_binary(key) do
    <<hash::signed-64, _rest::binary>> = :crypto.hash(:sha256, key)
    hash
  end
end
```
