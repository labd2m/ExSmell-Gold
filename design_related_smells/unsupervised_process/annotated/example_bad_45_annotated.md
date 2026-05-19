# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `LockServer.start/1`
- **Affected function(s):** `LockServer.start/1`, `LockManager.ensure_started/1`
- **Short explanation:** Each named lock is managed by a dedicated `GenServer` that enforces mutual exclusion, tracks the current holder, and implements TTL-based expiry. Starting these with `GenServer.start/3` outside any supervision tree means a lock process crash silently disappears — the lock is neither released nor re-acquired, leaving downstream code either deadlocked or entering a critical section without protection.

```elixir
defmodule LockServer do
  use GenServer

  @moduledoc """
  Node-local named mutex with TTL, re-entrancy tracking, and wait queues.
  Guarantees that only one caller at a time holds a given lock resource.
  """

  @default_ttl_ms 30_000
  @default_acquire_timeout_ms 10_000

  defstruct [
    :lock_name,
    :holder,
    :holder_ref,
    :acquired_at,
    :expires_at,
    :ttl_ms,
    wait_queue: [],
    acquisition_count: 0
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because lock servers are critical infrastructure
  # that must remain alive for the correctness of any code relying on mutual
  # exclusion. Using `GenServer.start/3` places each lock process outside any
  # supervision tree. A crash silently removes the lock: any waiting caller's
  # `acquire/2` call will hang or raise, the lock is never released, and
  # concurrent processes may enter a critical section simultaneously without
  # knowing the guard is gone.
  def start(lock_name, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    GenServer.start(__MODULE__, %{lock_name: lock_name, ttl_ms: ttl_ms}, name: via(lock_name))
  end
  # VALIDATION: SMELL END

  def acquire(lock_name, caller_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_acquire_timeout_ms)
    GenServer.call(via(lock_name), {:acquire, caller_id}, timeout)
  end

  def release(lock_name, caller_id) do
    GenServer.call(via(lock_name), {:release, caller_id})
  end

  def force_release(lock_name) do
    GenServer.call(via(lock_name), :force_release)
  end

  def status(lock_name) do
    GenServer.call(via(lock_name), :status)
  end

  defp via(name), do: {:via, Registry, {LockRegistry, name}}

  ## Callbacks

  @impl true
  def init(%{lock_name: name, ttl_ms: ttl}) do
    {:ok, %__MODULE__{lock_name: name, ttl_ms: ttl}}
  end

  @impl true
  def handle_call({:acquire, caller_id}, from, %{holder: nil} = state) do
    ref = Process.monitor(elem(from, 0))
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, state.ttl_ms, :millisecond)

    Process.send_after(self(), {:expire, caller_id}, state.ttl_ms)

    new_state = %{state |
      holder: caller_id,
      holder_ref: ref,
      acquired_at: now,
      expires_at: expires_at,
      acquisition_count: state.acquisition_count + 1
    }

    {:reply, {:ok, :acquired}, new_state}
  end

  def handle_call({:acquire, caller_id}, from, state) do
    new_state = %{state | wait_queue: state.wait_queue ++ [{caller_id, from}]}
    {:noreply, new_state}
  end

  def handle_call({:release, caller_id}, _from, %{holder: caller_id} = state) do
    Process.demonitor(state.holder_ref, [:flush])
    {new_state, reply} = grant_next(state)
    {:reply, {:ok, reply}, new_state}
  end

  def handle_call({:release, caller_id}, _from, state) do
    {:reply, {:error, {:not_holder, caller_id, state.holder}}, state}
  end

  def handle_call(:force_release, _from, state) do
    if state.holder_ref, do: Process.demonitor(state.holder_ref, [:flush])
    {new_state, _} = grant_next(%{state | holder: nil, holder_ref: nil})
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      lock_name: state.lock_name,
      holder: state.holder,
      acquired_at: state.acquired_at,
      expires_at: state.expires_at,
      queue_length: length(state.wait_queue),
      total_acquisitions: state.acquisition_count
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {new_state, _} = grant_next(%{state | holder: nil, holder_ref: nil})
    {:noreply, new_state}
  end

  def handle_info({:expire, caller_id}, %{holder: caller_id} = state) do
    Process.demonitor(state.holder_ref, [:flush])
    {new_state, _} = grant_next(%{state | holder: nil, holder_ref: nil})
    {:noreply, new_state}
  end

  def handle_info({:expire, _old_caller}, state), do: {:noreply, state}

  defp grant_next(%{wait_queue: []} = state) do
    {%{state | holder: nil, holder_ref: nil, acquired_at: nil, expires_at: nil}, :no_waiters}
  end

  defp grant_next(%{wait_queue: [{next_caller, from} | rest]} = state) do
    ref = Process.monitor(elem(from, 0))
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, state.ttl_ms, :millisecond)

    GenServer.reply(from, {:ok, :acquired})

    new_state = %{state |
      holder: next_caller,
      holder_ref: ref,
      acquired_at: now,
      expires_at: expires_at,
      wait_queue: rest,
      acquisition_count: state.acquisition_count + 1
    }

    {new_state, :granted_to_next}
  end
end

defmodule LockManager do
  @moduledoc "Convenience wrapper for acquiring and releasing named locks."

  def with_lock(lock_name, caller_id, fun, opts \\ []) do
    ensure_started(lock_name, opts)

    case LockServer.acquire(lock_name, caller_id, opts) do
      {:ok, :acquired} ->
        try do
          {:ok, fun.()}
        after
          LockServer.release(lock_name, caller_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_started(lock_name, opts \\ []) do
    case LockServer.start(lock_name, opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```
