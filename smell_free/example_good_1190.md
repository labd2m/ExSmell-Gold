```elixir
defmodule Coordination.DistributedLock do
  @moduledoc """
  Provides mutual exclusion across cluster nodes using PostgreSQL advisory
  locks. Each lock is keyed by a namespaced string, hashed to a stable
  64-bit integer for use with `pg_try_advisory_lock`.
  """

  alias Coordination.Repo

  @type lock_key :: String.t()
  @type lock_result :: {:ok, term()} | {:error, :already_locked | term()}

  @spec with_lock(lock_key(), (-> {:ok, term()} | {:error, term()})) :: lock_result()
  def with_lock(key, fun) when is_binary(key) and is_function(fun, 0) do
    lock_id = key_to_lock_id(key)

    case acquire(lock_id) do
      :acquired ->
        try do
          fun.()
        after
          release(lock_id)
        end

      :contended ->
        {:error, :already_locked}
    end
  end

  @spec with_lock_wait(lock_key(), (-> {:ok, term()} | {:error, term()}), pos_integer()) ::
          lock_result()
  def with_lock_wait(key, fun, timeout_ms \\ 5_000)
      when is_binary(key) and is_function(fun, 0) and is_integer(timeout_ms) do
    lock_id = key_to_lock_id(key)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case poll_until_acquired(lock_id, deadline) do
      :acquired ->
        try do
          fun.()
        after
          release(lock_id)
        end

      :timeout ->
        {:error, :already_locked}
    end
  end

  @spec held?(lock_key()) :: boolean()
  def held?(key) when is_binary(key) do
    lock_id = key_to_lock_id(key)

    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = $1 LIMIT 1",
        [lock_id]
      )

    rows != []
  end

  @spec acquire(integer()) :: :acquired | :contended
  defp acquire(lock_id) do
    {:ok, %{rows: [[result]]}} =
      Repo.query("SELECT pg_try_advisory_lock($1)", [lock_id])

    if result, do: :acquired, else: :contended
  end

  @spec release(integer()) :: :ok
  defp release(lock_id) do
    Repo.query("SELECT pg_advisory_unlock($1)", [lock_id])
    :ok
  end

  @spec poll_until_acquired(integer(), integer()) :: :acquired | :timeout
  defp poll_until_acquired(lock_id, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        :timeout

      acquire(lock_id) == :acquired ->
        :acquired

      true ->
        Process.sleep(100)
        poll_until_acquired(lock_id, deadline)
    end
  end

  @spec key_to_lock_id(lock_key()) :: integer()
  defp key_to_lock_id(key) do
    <<value::signed-64, _::binary>> = :crypto.hash(:sha256, key)
    value
  end
end
```
