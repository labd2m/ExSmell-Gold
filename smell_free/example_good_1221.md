```elixir
defmodule Distributed.Lock do
  @moduledoc """
  A named distributed lock backed by a `Registry` partition.
  Acquiring a lock registers the calling process under the lock key.
  Releasing it (or the process crashing) automatically frees the lock.
  Locks are per-node; use an external store for cross-node coordination.
  """

  @registry Distributed.Lock.Registry

  @type lock_key :: String.t()
  @type acquire_opts :: [timeout_ms: pos_integer()]

  @spec acquire(lock_key(), acquire_opts()) :: {:ok, :acquired} | {:error, :already_locked}
  def acquire(key, opts \\ []) when is_binary(key) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    deadline = System.monotonic_time(:millisecond) + timeout
    do_acquire(key, deadline)
  end

  @spec release(lock_key()) :: :ok
  def release(key) when is_binary(key) do
    Registry.unregister(@registry, key)
    :ok
  end

  @spec held_by(lock_key()) :: {:ok, pid()} | {:error, :not_locked}
  def held_by(key) when is_binary(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_locked}
    end
  end

  @spec with_lock(lock_key(), (-> term()), acquire_opts()) ::
          {:ok, term()} | {:error, :already_locked} | {:error, {:raised, term()}}
  def with_lock(key, fun, opts \\ []) when is_binary(key) and is_function(fun, 0) do
    with {:ok, :acquired} <- acquire(key, opts) do
      result =
        try do
          {:ok, fun.()}
        rescue
          err -> {:error, {:raised, err}}
        end

      release(key)
      result
    end
  end

  @spec all_locks() :: list(lock_key())
  def all_locks do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp do_acquire(key, deadline) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        {:ok, :acquired}

      {:error, {:already_registered, _}} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :already_locked}
        else
          Process.sleep(10)
          do_acquire(key, deadline)
        end
    end
  end
end

defmodule Distributed.Lock.Supervisor do
  @moduledoc """
  Starts and supervises the lock registry under the application tree.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Distributed.Lock.Registry, partitions: System.schedulers_online()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
