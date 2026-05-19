# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `ApiQuotaGovernorTask` — `Task` acting as a persistent quota management server
- **Affected function(s):** `start_governor/1`, `governor_loop/1`
- **Short explanation:** The `Task` maintains quota state for multiple API tenants, handles allow/deny decisions, accepts reset commands, produces reports, and schedules periodic window resets — all behaviors of a `GenServer`, not a one-shot async computation.

```elixir
defmodule MyApp.ApiQuotaGovernorTask do
  @moduledoc """
  Enforces per-tenant API quota limits with sliding windows,
  quota overrides, and periodic rollover.
  """

  alias MyApp.{Repo, AlertService, AuditLog}
  alias MyApp.Api.{TenantQuota, QuotaUsage}

  @window_seconds 3_600
  @rollover_interval_ms 60_000

  def start_governor(config) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because a Task is used as a long-running server
    # that manages per-tenant quota windows, responds to allow/deny requests with
    # replies, handles administrative overrides, generates usage reports, and
    # runs periodic window rollover — all sustained interactive behaviors that
    # belong in a GenServer. A Task is only suited for a single isolated
    # asynchronous computation, not a multi-client server with ongoing state.
    Task.start_link(fn ->
      quotas =
        Repo.all(TenantQuota)
        |> Enum.into(%{}, &{&1.tenant_id, &1})

      state = %{
        config: config,
        quotas: quotas,
        usage: %{},
        overrides: %{},
        window_start: DateTime.utc_now()
      }

      schedule_rollover()
      governor_loop(state)
    end)
  end

  defp schedule_rollover do
    Process.send_after(self(), :rollover, @rollover_interval_ms)
  end

  defp governor_loop(state) do
    receive do
      {:check_and_consume, from, tenant_id, cost} ->
        quota = Map.get(state.quotas, tenant_id)
        override = Map.get(state.overrides, tenant_id)
        current_usage = Map.get(state.usage, tenant_id, 0)
        effective_limit = override || (quota && quota.requests_per_hour) || state.config.default_limit

        if current_usage + cost > effective_limit do
          AlertService.notify_quota_exceeded(tenant_id, current_usage, effective_limit)
          send(from, {:error, :quota_exceeded, %{used: current_usage, limit: effective_limit}})
          governor_loop(state)
        else
          new_usage = Map.put(state.usage, tenant_id, current_usage + cost)
          send(from, {:ok, %{remaining: effective_limit - current_usage - cost}})
          governor_loop(%{state | usage: new_usage})
        end

      {:set_override, from, tenant_id, limit} ->
        AuditLog.record(:quota_override, %{tenant_id: tenant_id, limit: limit})
        new_overrides = Map.put(state.overrides, tenant_id, limit)
        send(from, :ok)
        governor_loop(%{state | overrides: new_overrides})

      {:remove_override, from, tenant_id} ->
        AuditLog.record(:quota_override_removed, %{tenant_id: tenant_id})
        new_overrides = Map.delete(state.overrides, tenant_id)
        send(from, :ok)
        governor_loop(%{state | overrides: new_overrides})

      {:get_usage_report, from} ->
        report =
          Enum.map(state.usage, fn {tenant_id, used} ->
            quota = Map.get(state.quotas, tenant_id)
            override = Map.get(state.overrides, tenant_id)
            limit = override || (quota && quota.requests_per_hour) || state.config.default_limit

            %{
              tenant_id: tenant_id,
              used: used,
              limit: limit,
              pct_used: Float.round(used / limit * 100, 2)
            }
          end)
          |> Enum.sort_by(& &1.pct_used, :desc)

        send(from, {:ok, report})
        governor_loop(state)

      {:reset_tenant, from, tenant_id} ->
        AuditLog.record(:quota_manual_reset, %{tenant_id: tenant_id})
        new_usage = Map.put(state.usage, tenant_id, 0)
        send(from, :ok)
        governor_loop(%{state | usage: new_usage})

      :rollover ->
        now = DateTime.utc_now()
        elapsed = DateTime.diff(now, state.window_start, :second)

        new_state =
          if elapsed >= @window_seconds do
            AuditLog.record(:quota_window_rollover, %{window_start: state.window_start})
            %{state | usage: %{}, window_start: now}
          else
            state
          end

        schedule_rollover()
        governor_loop(new_state)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  def check_and_consume(pid, tenant_id, cost \\ 1) do
    send(pid, {:check_and_consume, self(), tenant_id, cost})

    receive do
      {:ok, info} -> {:ok, info}
      {:error, reason, meta} -> {:error, reason, meta}
    after
      3_000 -> {:error, :timeout, %{}}
    end
  end

  def get_usage_report(pid) do
    send(pid, {:get_usage_report, self()})

    receive do
      {:ok, report} -> {:ok, report}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def set_override(pid, tenant_id, limit) do
    send(pid, {:set_override, self(), tenant_id, limit})

    receive do
      :ok -> :ok
    after
      3_000 -> {:error, :timeout}
    end
  end

  def reset_tenant(pid, tenant_id) do
    send(pid, {:reset_tenant, self(), tenant_id})

    receive do
      :ok -> :ok
    after
      3_000 -> {:error, :timeout}
    end
  end
end
```
