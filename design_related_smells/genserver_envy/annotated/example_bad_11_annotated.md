# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `RateLimiterAgent` module — `Agent` executing rate-limit enforcement and notification logic
- **Affected function(s):** `check_and_record/2`, `block_client/2`, `sweep_windows/0`
- **Short explanation:** Rate-limiting involves inspecting request windows, enforcing policies, blocking clients, and sending alerts — operational logic far beyond the simple state-sharing role of an `Agent`.

```elixir
defmodule MyApp.RateLimiterAgent do
  @moduledoc """
  Token-bucket rate limiter that tracks request counts per client key,
  enforces per-window limits, and blocks repeat offenders.
  """

  use Agent

  alias MyApp.{AlertService, AuditLog}

  @window_seconds 60
  @default_limit 100
  @block_threshold 3

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          windows: %{},
          blocked: %{},
          violations: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def is_blocked?(client_key) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.blocked, client_key) do
        nil -> false
        expires_at -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      end
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent is used to implement a
  # complete rate-limiting enforcement system, including window management,
  # violation tracking, client blocking, and external alert notifications.
  # These coordinated side effects and multi-step decision logic are the
  # purview of a GenServer, not an Agent's simple state-sharing purpose.

  def check_and_record(client_key, limit \\ @default_limit) do
    Agent.get_and_update(__MODULE__, fn state ->
      now = DateTime.utc_now()

      case Map.get(state.blocked, client_key) do
        expires_at when not is_nil(expires_at) ->
          if DateTime.compare(expires_at, now) == :gt do
            {{:error, {:blocked, expires_at}}, state}
          else
            new_blocked = Map.delete(state.blocked, client_key)
            check_window({:ok, :allowed}, %{state | blocked: new_blocked}, client_key, limit, now)
          end

        nil ->
          check_window({:ok, :allowed}, state, client_key, limit, now)
      end
    end)
  end

  defp check_window(_default, state, client_key, limit, now) do
    window_key = {client_key, window_bucket(now)}
    count = Map.get(state.windows, window_key, 0)

    if count >= limit do
      violations = Map.get(state.violations, client_key, 0) + 1
      new_violations = Map.put(state.violations, client_key, violations)

      new_state =
        if violations >= @block_threshold do
          block_until = DateTime.add(now, 3600, :second)
          AlertService.send_alert(:rate_limit_block, %{client: client_key, until: block_until})
          AuditLog.record(:client_blocked, %{client_key: client_key, violations: violations})
          %{state | violations: new_violations, blocked: Map.put(state.blocked, client_key, block_until)}
        else
          AlertService.send_alert(:rate_limit_exceeded, %{client: client_key, count: count})
          %{state | violations: new_violations}
        end

      {{:error, :rate_limited}, new_state}
    else
      new_windows = Map.put(state.windows, window_key, count + 1)
      {{:ok, limit - count - 1}, %{state | windows: new_windows}}
    end
  end

  def block_client(client_key, duration_seconds) do
    Agent.get_and_update(__MODULE__, fn state ->
      block_until = DateTime.add(DateTime.utc_now(), duration_seconds, :second)
      AuditLog.record(:manual_block, %{client_key: client_key, until: block_until})
      AlertService.send_alert(:manual_block, %{client: client_key})
      new_state = %{state | blocked: Map.put(state.blocked, client_key, block_until)}
      {:ok, new_state}
    end)
  end

  def sweep_windows do
    now = DateTime.utc_now()
    cutoff_bucket = window_bucket(DateTime.add(now, -@window_seconds * 2, :second))

    Agent.update(__MODULE__, fn state ->
      fresh_windows =
        state.windows
        |> Enum.reject(fn {{_key, bucket}, _count} -> bucket < cutoff_bucket end)
        |> Map.new()

      fresh_blocked =
        state.blocked
        |> Enum.reject(fn {_key, expires_at} -> DateTime.compare(expires_at, now) == :lt end)
        |> Map.new()

      %{state | windows: fresh_windows, blocked: fresh_blocked}
    end)
  end

  # VALIDATION: SMELL END

  defp window_bucket(dt) do
    dt
    |> DateTime.to_unix()
    |> div(@window_seconds)
  end

  def stats do
    Agent.get(__MODULE__, fn state ->
      %{
        active_windows: map_size(state.windows),
        blocked_clients: map_size(state.blocked),
        tracked_violations: map_size(state.violations)
      }
    end)
  end
end
```
