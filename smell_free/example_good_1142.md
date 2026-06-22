```elixir
defmodule Distlock.AdvisoryLock do
  @moduledoc """
  Distributed mutual exclusion using PostgreSQL advisory locks acquired
  through an Ecto repository. Locks are session-scoped and automatically
  released when the database connection is returned to the pool.

  Use `with_lock/3` to execute a function exclusively across all nodes
  sharing the same Postgres instance.
  """

  alias Ecto.Adapters.SQL

  @type lock_key :: String.t()
  @type lock_result(t) :: {:ok, t} | {:error, :already_locked | String.t()}

  @spec with_lock(module(), lock_key(), (() -> term()), keyword()) :: lock_result(term())
  def with_lock(repo, key, fun, opts \\ [])
      when is_atom(repo) and is_binary(key) and is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    numeric_key = derive_lock_key(key)

    repo.transaction(fn ->
      case acquire(repo, numeric_key, timeout_ms) do
        :acquired ->
          fun.()

        :not_acquired ->
          repo.rollback(:already_locked)
      end
    end)
    |> normalize_transaction_result()
  end

  @spec try_lock(module(), lock_key()) :: :acquired | :not_acquired
  def try_lock(repo, key) when is_atom(repo) and is_binary(key) do
    numeric_key = derive_lock_key(key)
    acquire_nowait(repo, numeric_key)
  end

  @spec release(module(), lock_key()) :: :ok
  def release(repo, key) when is_atom(repo) and is_binary(key) do
    numeric_key = derive_lock_key(key)

    SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [numeric_key])
    :ok
  end

  @spec held_by_session?(module(), lock_key()) :: boolean()
  def held_by_session?(repo, key) when is_atom(repo) and is_binary(key) do
    numeric_key = derive_lock_key(key)

    case SQL.query(repo, "SELECT count(*) FROM pg_locks WHERE objid = $1 AND locktype = 'advisory' AND granted = true", [numeric_key]) do
      {:ok, %{rows: [[count]]}} -> count > 0
      _ -> false
    end
  end

  @spec acquire(module(), integer(), pos_integer()) :: :acquired | :not_acquired
  defp acquire(repo, numeric_key, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    attempt_acquire(repo, numeric_key, deadline)
  end

  @spec attempt_acquire(module(), integer(), integer()) :: :acquired | :not_acquired
  defp attempt_acquire(repo, numeric_key, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      :not_acquired
    else
      case acquire_nowait(repo, numeric_key) do
        :acquired ->
          :acquired

        :not_acquired ->
          Process.sleep(50)
          attempt_acquire(repo, numeric_key, deadline)
      end
    end
  end

  @spec acquire_nowait(module(), integer()) :: :acquired | :not_acquired
  defp acquire_nowait(repo, numeric_key) do
    case SQL.query(repo, "SELECT pg_try_advisory_lock($1)", [numeric_key]) do
      {:ok, %{rows: [[true]]}} -> :acquired
      {:ok, %{rows: [[false]]}} -> :not_acquired
      {:error, _} -> :not_acquired
    end
  end

  @spec derive_lock_key(String.t()) :: integer()
  defp derive_lock_key(key) do
    <<value::signed-integer-64, _rest::binary>> =
      :crypto.hash(:sha256, key) |> binary_part(0, 8) |> pad_to_8()

    value
  end

  @spec pad_to_8(binary()) :: binary()
  defp pad_to_8(bin) when byte_size(bin) >= 8, do: binary_part(bin, 0, 8)
  defp pad_to_8(bin), do: bin <> :binary.copy(<<0>>, 8 - byte_size(bin))

  @spec normalize_transaction_result({:ok, term()} | {:error, term()}) :: lock_result(term())
  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, :already_locked}), do: {:error, :already_locked}
  defp normalize_transaction_result({:error, reason}), do: {:error, inspect(reason)}
end

defmodule Distlock.KeyedMutex do
  @moduledoc """
  Convenience wrapper providing named mutex operations backed by
  `Distlock.AdvisoryLock`. Useful for idempotent job deduplication
  or resource-scoped critical sections.
  """

  @spec guarded(module(), String.t(), String.t(), (() -> term()), keyword()) ::
          {:ok, term()} | {:error, :already_locked | String.t()}
  def guarded(repo, namespace, resource_id, fun, opts \\ [])
      when is_atom(repo) and is_binary(namespace) and is_binary(resource_id) do
    lock_key = "#{namespace}:#{resource_id}"
    Distlock.AdvisoryLock.with_lock(repo, lock_key, fun, opts)
  end
end
```
