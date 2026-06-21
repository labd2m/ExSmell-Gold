```elixir
defmodule DistributedLock do
  @moduledoc """
  Named mutual exclusion backed by PostgreSQL advisory locks.

  Advisory locks are session-scoped in PostgreSQL and released automatically
  when the database connection closes, making them safe even under process
  crashes. `with_lock/3` acquires the lock, runs the given function, and
  unconditionally releases it. Non-blocking acquisition is supported via
  `try_lock/2` for callers that must not wait.
  """

  alias DistributedLock.Repo

  @type lock_key :: String.t()
  @type lock_result(t) :: {:ok, t} | {:error, :lock_timeout | :lock_unavailable | term()}

  @spec with_lock(lock_key(), pos_integer(), (-> term())) :: lock_result(term())
  def with_lock(key, timeout_ms \\ 5_000, fun)
      when is_binary(key) and is_integer(timeout_ms) and is_function(fun, 0) do
    lock_id = key_to_int(key)

    Repo.transaction(fn ->
      case acquire(lock_id, timeout_ms) do
        :ok ->
          result = fun.()
          release(lock_id)
          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @spec try_lock(lock_key(), (-> term())) :: lock_result(term())
  def try_lock(key, fun) when is_binary(key) and is_function(fun, 0) do
    lock_id = key_to_int(key)

    Repo.transaction(fn ->
      case try_acquire(lock_id) do
        :ok ->
          result = fun.()
          release(lock_id)
          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @spec held?(lock_key()) :: boolean()
  def held?(key) when is_binary(key) do
    lock_id = key_to_int(key)

    case Repo.query(
           "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1",
           [lock_id]
         ) do
      {:ok, %{rows: [[count]]}} -> count > 0
      _ -> false
    end
  end

  defp acquire(lock_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_acquire(lock_id, deadline)
  end

  defp do_acquire(lock_id, deadline) do
    case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [lock_id]) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: [[false]]}} ->
        if System.monotonic_time(:millisecond) < deadline do
          :timer.sleep(50)
          do_acquire(lock_id, deadline)
        else
          {:error, :lock_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_acquire(lock_id) do
    case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [lock_id]) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :lock_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release(lock_id) do
    Repo.query("SELECT pg_advisory_xact_unlock($1)", [lock_id])
  end

  defp key_to_int(key) when is_binary(key) do
    <<int::big-signed-64, _rest::binary>> = :crypto.hash(:sha256, key)
    int
  end
end
```
