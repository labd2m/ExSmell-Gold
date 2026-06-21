```elixir
defmodule Platform.DistributedLock do
  @moduledoc """
  A node-local distributed lock backed by a GenServer and a Registry.

  Acquires an exclusive lock on a named resource for a caller process.
  The lock is automatically released when the holder process exits,
  preventing deadlocks due to unexpected crashes.
  """

  use GenServer

  require Logger

  @type lock_name :: String.t()
  @type acquire_result :: {:ok, reference()} | {:error, :already_locked}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to acquire an exclusive lock on `name`.

  Returns `{:ok, lock_ref}` if the lock was acquired. The caller must
  release the lock via `release/1` when done. The lock is also
  released automatically if the calling process exits.
  """
  @spec acquire(lock_name(), keyword()) :: acquire_result()
  def acquire(name, opts \\ []) when is_binary(name) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(__MODULE__, {:acquire, name, self()}, timeout)
  end

  @doc """
  Releases a previously acquired lock. The `lock_ref` must match the one
  returned by `acquire/2`. Returns `{:error, :not_owner}` on mismatch.
  """
  @spec release(reference()) :: :ok | {:error, :not_owner | :not_found}
  def release(lock_ref) when is_reference(lock_ref) do
    GenServer.call(__MODULE__, {:release, lock_ref, self()})
  end

  @doc "Returns the names of all currently held locks."
  @spec held_locks() :: [lock_name()]
  def held_locks, do: GenServer.call(__MODULE__, :held_locks)

  @impl GenServer
  def init(_opts) do
    {:ok, %{locks: %{}, refs: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, name, pid}, _from, state) do
    case Map.get(state.locks, name) do
      nil ->
        lock_ref = make_ref()
        monitor_ref = Process.monitor(pid)
        entry = %{holder: pid, lock_ref: lock_ref, monitor_ref: monitor_ref}
        new_state = state
          |> put_in([:locks, name], entry)
          |> put_in([:refs, lock_ref], name)
        {:reply, {:ok, lock_ref}, new_state}

      _held ->
        {:reply, {:error, :already_locked}, state}
    end
  end

  @impl GenServer
  def handle_call({:release, lock_ref, pid}, _from, state) do
    case Map.get(state.refs, lock_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      name ->
        case Map.get(state.locks, name) do
          %{holder: ^pid, monitor_ref: mref} ->
            Process.demonitor(mref, [:flush])
            new_state = state
              |> update_in([:locks], &Map.delete(&1, name))
              |> update_in([:refs], &Map.delete(&1, lock_ref))
            {:reply, :ok, new_state}

          _ ->
            {:reply, {:error, :not_owner}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:held_locks, _from, state) do
    {:reply, Map.keys(state.locks), state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    new_state = release_by_monitor(state, monitor_ref)
    {:noreply, new_state}
  end

  defp release_by_monitor(state, monitor_ref) do
    entry = Enum.find(state.locks, fn {_name, e} -> e.monitor_ref == monitor_ref end)

    case entry do
      nil ->
        state

      {name, %{lock_ref: lock_ref}} ->
        Logger.debug("[DistributedLock] Auto-releasing lock after holder exit", lock: name)
        state
        |> update_in([:locks], &Map.delete(&1, name))
        |> update_in([:refs], &Map.delete(&1, lock_ref))
    end
  end
end
```
