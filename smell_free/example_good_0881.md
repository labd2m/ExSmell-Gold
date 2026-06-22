```elixir
defmodule MyApp.Infra.MutexLock do
  @moduledoc """
  A named mutex lock implemented as a supervised GenServer. Only one
  caller can hold a named lock at a time; others block until the lock is
  released or the timeout expires. The lock is automatically released
  when the holding process exits, preventing deadlocks from crashing
  callers.
  """

  use GenServer

  @default_acquire_timeout_ms 5_000
  @default_lock_timeout_ms 30_000

  @type lock_name :: atom() | String.t()

  @doc "Starts the mutex lock server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires `lock_name` and runs `fun` exclusively. Other callers block
  until the lock is released. Returns `{:ok, result}` or
  `{:error, :timeout}` when acquisition times out.
  """
  @spec with_lock(lock_name(), (-> result), keyword()) ::
          {:ok, result} | {:error, :timeout}
        when result: term()
  def with_lock(lock_name, fun, opts \\ [])
      when (is_atom(lock_name) or is_binary(lock_name)) and is_function(fun, 0) do
    acquire_timeout = Keyword.get(opts, :acquire_timeout_ms, @default_acquire_timeout_ms)

    case acquire(lock_name, acquire_timeout) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release(lock_name)
        end

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  @doc "Returns the list of currently held lock names."
  @spec held_locks() :: [lock_name()]
  def held_locks, do: GenServer.call(__MODULE__, :held_locks)

  @spec acquire(lock_name(), pos_integer()) :: :ok | {:error, :timeout}
  defp acquire(lock_name, timeout_ms) do
    GenServer.call(__MODULE__, {:acquire, lock_name, self()}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec release(lock_name()) :: :ok
  defp release(lock_name) do
    GenServer.cast(__MODULE__, {:release, lock_name})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{locks: %{}, waiters: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, lock_name, caller_pid}, from, state) do
    case Map.get(state.locks, lock_name) do
      nil ->
        ref = Process.monitor(caller_pid)
        new_locks = Map.put(state.locks, lock_name, {caller_pid, ref})
        {:reply, :ok, %{state | locks: new_locks}}

      _held ->
        queue = Map.get(state.waiters, lock_name, :queue.new())
        new_queue = :queue.in({from, caller_pid}, queue)
        {:noreply, %{state | waiters: Map.put(state.waiters, lock_name, new_queue)}}
    end
  end

  @impl GenServer
  def handle_call(:held_locks, _from, state) do
    {:reply, Map.keys(state.locks), state}
  end

  @impl GenServer
  def handle_cast({:release, lock_name}, state) do
    {_, state} = do_release(lock_name, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    lock_name =
      Enum.find_value(state.locks, fn {name, {_pid, r}} ->
        if r == ref, do: name
      end)

    if lock_name do
      {_, new_state} = do_release(lock_name, state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @spec do_release(lock_name(), map()) :: {:ok, map()}
  defp do_release(lock_name, state) do
    case Map.get(state.locks, lock_name) do
      nil ->
        {:ok, state}

      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        new_locks = Map.delete(state.locks, lock_name)

        case Map.get(state.waiters, lock_name, :queue.new()) do
          queue when :queue.is_empty(queue) ->
            {:ok, %{state | locks: new_locks}}

          queue ->
            {{:value, {from, next_pid}}, rest_queue} = :queue.out(queue)
            next_ref = Process.monitor(next_pid)
            granted_locks = Map.put(new_locks, lock_name, {next_pid, next_ref})
            GenServer.reply(from, :ok)
            {:ok, %{state | locks: granted_locks, waiters: Map.put(state.waiters, lock_name, rest_queue)}}
        end
    end
  end
end
```
