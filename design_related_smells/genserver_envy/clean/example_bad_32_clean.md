```elixir
defmodule MyApp.LockManagerTask do
  @moduledoc """
  In-process distributed lock manager supporting TTL-based locks,
  lock queuing, and automatic expiry for critical section protection.
  """

  alias MyApp.{AuditLog, MetricsCollector}
  alias MyApp.Locks.{Lock, WaitEntry}

  @default_ttl_ms 30_000
  @sweep_interval_ms 5_000
  @max_waiters 50

  def start_lock_manager(config \\ %{}) do
    Task.start_link(fn ->
      state = %{
        config: Map.merge(%{default_ttl_ms: @default_ttl_ms}, config),
        locks: %{},
        waiters: %{},
        acquired_count: 0,
        contention_count: 0
      }

      schedule_sweep()
      lock_manager_loop(state)
    end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end

  defp lock_manager_loop(state) do
    receive do
      {:acquire, from, resource, opts} ->
        ttl_ms = Keyword.get(opts, :ttl_ms, state.config.default_ttl_ms)
        caller_ref = Keyword.get(opts, :ref, make_ref())

        case Map.fetch(state.locks, resource) do
          :error ->
            lock = %Lock{
              resource: resource,
              holder_ref: caller_ref,
              holder_pid: from,
              acquired_at: DateTime.utc_now(),
              expires_at: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
            }

            MetricsCollector.increment(:locks_acquired)
            send(from, {:ok, caller_ref})

            lock_manager_loop(%{
              state
              | locks: Map.put(state.locks, resource, lock),
                acquired_count: state.acquired_count + 1
            })

          {:ok, _existing_lock} ->
            waiters = Map.get(state.waiters, resource, [])

            if length(waiters) >= @max_waiters do
              send(from, {:error, :queue_full})
              lock_manager_loop(%{state | contention_count: state.contention_count + 1})
            else
              waiter = %WaitEntry{
                pid: from,
                ref: caller_ref,
                ttl_ms: ttl_ms,
                queued_at: DateTime.utc_now()
              }

              new_waiters = Map.put(state.waiters, resource, waiters ++ [waiter])
              MetricsCollector.increment(:lock_contentions)
              send(from, {:queued, caller_ref})

              lock_manager_loop(%{
                state
                | waiters: new_waiters,
                  contention_count: state.contention_count + 1
              })
            end
        end

      {:release, from, resource, holder_ref} ->
        case Map.fetch(state.locks, resource) do
          :error ->
            send(from, {:error, :not_locked})
            lock_manager_loop(state)

          {:ok, lock} when lock.holder_ref != holder_ref ->
            send(from, {:error, :not_lock_holder})
            lock_manager_loop(state)

          {:ok, _lock} ->
            send(from, :ok)
            new_state = assign_to_next_waiter(state, resource)
            lock_manager_loop(new_state)
        end

      :sweep_expired ->
        now = DateTime.utc_now()

        {expired_locks, active_locks} =
          Enum.split_with(state.locks, fn {_resource, lock} ->
            DateTime.compare(lock.expires_at, now) == :lt
          end)

        new_state =
          Enum.reduce(expired_locks, %{state | locks: Map.new(active_locks)}, fn {resource, _lock},
                                                                                   acc ->
            AuditLog.record(:lock_expired, %{resource: resource})
            assign_to_next_waiter(acc, resource)
          end)

        schedule_sweep()
        lock_manager_loop(new_state)

      {:get_status, from, resource} ->
        lock = Map.get(state.locks, resource)
        waiters = Map.get(state.waiters, resource, [])
        send(from, {:ok, %{locked: not is_nil(lock), lock: lock, waiters: length(waiters)}})
        lock_manager_loop(state)

      {:get_stats, from} ->
        stats = %{
          locked_resources: map_size(state.locks),
          total_waiters: state.waiters |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
          acquired_count: state.acquired_count,
          contention_count: state.contention_count
        }
        send(from, {:ok, stats})
        lock_manager_loop(state)

      :stop ->
        :ok
    end
  end

  defp assign_to_next_waiter(state, resource) do
    case Map.get(state.waiters, resource, []) do
      [] ->
        %{state | locks: Map.delete(state.locks, resource), waiters: Map.delete(state.waiters, resource)}

      [next | rest] ->
        lock = %Lock{
          resource: resource,
          holder_ref: next.ref,
          holder_pid: next.pid,
          acquired_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), next.ttl_ms, :millisecond)
        }

        send(next.pid, {:lock_granted, next.ref})

        %{
          state
          | locks: Map.put(state.locks, resource, lock),
            waiters: Map.put(state.waiters, resource, rest),
            acquired_count: state.acquired_count + 1
        }
    end
  end

  def acquire(pid, resource, opts \\ []) do
    send(pid, {:acquire, self(), resource, opts})

    receive do
      {:ok, ref} -> {:ok, ref}
      {:queued, ref} -> {:queued, ref}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def release(pid, resource, holder_ref) do
    send(pid, {:release, self(), resource, holder_ref})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      3_000 -> {:error, :timeout}
    end
  end
end
```
