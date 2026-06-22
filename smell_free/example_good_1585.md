```elixir
defmodule DistributedLock.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

defmodule DistributedLock do
  @moduledoc """
  Provides exclusive distributed locking using PostgreSQL advisory locks.
  Locks are scoped by a deterministic integer derived from a string key
  and are automatically released when the database connection closes.

  ## Usage

      DistributedLock.with_lock("billing:customer:123", fn ->
        # exclusive work here
      end)

  """

  alias MyApp.Repo

  @type lock_result :: {:ok, term()} | {:error, :already_locked | term()}

  @spec with_lock(String.t(), (-> term()), keyword()) :: lock_result()
  def with_lock(key, function, opts \\ [])
      when is_binary(key) and is_function(function, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    lock_id = key_to_lock_id(key)

    Repo.transaction(
      fn ->
        case acquire_lock(lock_id, timeout_ms) do
          :ok -> function.()
          {:error, :already_locked} -> Repo.rollback(:already_locked)
        end
      end,
      timeout: timeout_ms + 1_000
    )
    |> unwrap()
  end

  @spec try_lock(String.t()) :: {:ok, boolean()}
  def try_lock(key) when is_binary(key) do
    lock_id = key_to_lock_id(key)

    result =
      Repo.query!(
        "SELECT pg_try_advisory_xact_lock($1)",
        [lock_id]
      )

    [[acquired]] = result.rows
    {:ok, acquired}
  end

  defp acquire_lock(lock_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    attempt_acquire(lock_id, deadline)
  end

  defp attempt_acquire(lock_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :already_locked}
    else
      result =
        Repo.query!(
          "SELECT pg_try_advisory_xact_lock($1)",
          [lock_id]
        )

      case result.rows do
        [[true]] -> :ok
        [[false]] ->
          Process.sleep(50)
          attempt_acquire(lock_id, deadline)
      end
    end
  end

  defp key_to_lock_id(key) do
    <<high::32, _::binary>> = :crypto.hash(:sha256, key)
    high
  end

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, :already_locked}), do: {:error, :already_locked}
  defp unwrap({:error, reason}), do: {:error, reason}
end
```
