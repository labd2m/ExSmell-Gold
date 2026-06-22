```elixir
defmodule Infra.DistributedLock do
  @moduledoc """
  Provides mutual exclusion across nodes using PostgreSQL session-level advisory locks.

  Locks are scoped to the database session and automatically released when the
  connection is returned to the pool. A lock key is derived deterministically
  from a caller-supplied string namespace.
  """

  alias Infra.DistributedLock.{KeyDeriver, LockResult}
  alias Ecto.Adapters.SQL

  @doc """
  Acquires an advisory lock for the given namespace, runs `fun`, then releases the lock.

  Returns `{:ok, fun_result}` if the lock was acquired and the function completed,
  or `{:error, :lock_unavailable}` if another process holds the lock.
  """
  @spec with_lock(String.t(), module(), (() -> term())) ::
          {:ok, term()} | {:error, :lock_unavailable | String.t()}
  def with_lock(namespace, repo, fun)
      when is_binary(namespace) and is_atom(repo) and is_function(fun, 0) do
    lock_key = KeyDeriver.derive(namespace)

    repo.transaction(fn ->
      case try_acquire(repo, lock_key) do
        %LockResult{acquired: true} ->
          result = fun.()
          release(repo, lock_key)
          result

        %LockResult{acquired: false} ->
          repo.rollback(:lock_unavailable)
      end
    end)
    |> unwrap_transaction_result()
  end

  @doc """
  Acquires a lock and holds it for the duration of the given timeout, blocking callers.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec with_blocking_lock(String.t(), module(), (() -> term()), pos_integer()) ::
          {:ok, term()} | {:error, String.t()}
  def with_blocking_lock(namespace, repo, fun, timeout_ms \\ 30_000)
      when is_binary(namespace) and is_atom(repo) and is_function(fun, 0) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    lock_key = KeyDeriver.derive(namespace)

    repo.transaction(
      fn ->
        acquire_blocking(repo, lock_key)
        result = fun.()
        release(repo, lock_key)
        result
      end,
      timeout: timeout_ms
    )
    |> unwrap_transaction_result()
  end

  # --- private helpers ---

  defp try_acquire(repo, lock_key) do
    %{rows: [[acquired]]} =
      SQL.query!(repo, "SELECT pg_try_advisory_xact_lock($1)", [lock_key])

    %LockResult{acquired: acquired, lock_key: lock_key}
  end

  defp acquire_blocking(repo, lock_key) do
    SQL.query!(repo, "SELECT pg_advisory_xact_lock($1)", [lock_key])
  end

  defp release(repo, lock_key) do
    SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [lock_key])
  end

  defp unwrap_transaction_result({:ok, result}), do: {:ok, result}
  defp unwrap_transaction_result({:error, :lock_unavailable}), do: {:error, :lock_unavailable}
  defp unwrap_transaction_result({:error, reason}), do: {:error, "lock transaction failed: #{inspect(reason)}"}
end

defmodule Infra.DistributedLock.KeyDeriver do
  @moduledoc "Derives a stable 64-bit integer lock key from an arbitrary string namespace."

  @spec derive(String.t()) :: integer()
  def derive(namespace) when is_binary(namespace) do
    <<key::signed-integer-64, _::binary>> =
      :crypto.hash(:sha256, namespace)

    key
  end
end

defmodule Infra.DistributedLock.LockResult do
  @moduledoc false

  @enforce_keys [:acquired, :lock_key]
  defstruct [:acquired, :lock_key]

  @type t :: %__MODULE__{
          acquired: boolean(),
          lock_key: integer()
        }
end
```
