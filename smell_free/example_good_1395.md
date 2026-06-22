**File:** `example_good_1395.md`

```elixir
defmodule DistributedLock.LockKey do
  @moduledoc """
  Converts a namespaced lock name into a stable 64-bit integer
  suitable for use as a PostgreSQL advisory lock key.
  """

  @spec to_integer(String.t()) :: integer()
  def to_integer(name) when is_binary(name) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, name)

    key
  end
end

defmodule DistributedLock.Result do
  @moduledoc "Represents the outcome of a lock acquisition attempt."

  @enforce_keys [:acquired, :key]
  defstruct [:acquired, :key, :lock_integer]

  @type t :: %__MODULE__{
          acquired: boolean(),
          key: String.t(),
          lock_integer: integer()
        }
end

defmodule DistributedLock do
  @moduledoc """
  Provides distributed mutual exclusion using PostgreSQL session-level
  advisory locks. Locks are automatically released when the database
  connection is returned to the pool.

  Use `with_lock/3` for scoped, automatically released locks.
  Use `try_lock/2` and `release/2` for manual lifecycle control.
  """

  alias DistributedLock.{LockKey, Result}
  alias MyApp.Repo

  import Ecto.Adapters.SQL, only: [query!: 3]

  @type lock_result :: {:ok, term()} | {:error, :already_locked} | {:error, term()}

  @spec with_lock(String.t(), keyword(), (-> term())) :: lock_result()
  def with_lock(name, opts \\ [], func) when is_binary(name) and is_function(func, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    Repo.transaction(fn ->
      case acquire_transactional(name, timeout_ms) do
        %Result{acquired: true} ->
          func.()

        %Result{acquired: false} ->
          Repo.rollback(:already_locked)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec try_lock(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def try_lock(name, _opts \\ []) when is_binary(name) do
    key = LockKey.to_integer(name)

    case query!(Repo, "SELECT pg_try_advisory_lock($1)", [key]) do
      %{rows: [[true]]} ->
        {:ok, %Result{acquired: true, key: name, lock_integer: key}}

      %{rows: [[false]]} ->
        {:ok, %Result{acquired: false, key: name, lock_integer: key}}

      error ->
        {:error, error}
    end
  end

  @spec release(String.t()) :: :ok | {:error, term()}
  def release(name) when is_binary(name) do
    key = LockKey.to_integer(name)

    case query!(Repo, "SELECT pg_advisory_unlock($1)", [key]) do
      %{rows: [[true]]} -> :ok
      %{rows: [[false]]} -> {:error, :lock_not_held}
      error -> {:error, error}
    end
  end

  defp acquire_transactional(name, timeout_ms) do
    key = LockKey.to_integer(name)
    timeout_s = div(timeout_ms, 1_000)

    query!(Repo, "SET LOCAL lock_timeout = '#{timeout_s}s'", [])

    case query!(Repo, "SELECT pg_try_advisory_xact_lock($1)", [key]) do
      %{rows: [[acquired]]} ->
        %Result{acquired: acquired, key: name, lock_integer: key}
    end
  rescue
    _e in Postgrex.Error -> %Result{acquired: false, key: name, lock_integer: LockKey.to_integer(name)}
  end

  defp unwrap_transaction_result({:ok, result}), do: {:ok, result}
  defp unwrap_transaction_result({:error, :already_locked}), do: {:error, :already_locked}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end

defmodule DistributedLock.Supervisor do
  @moduledoc "Supervises any ancillary processes required by the lock subsystem."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
```
