# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `QuotaEnforcer`, `QuotaResetter`, `QuotaAuditor`, and `QuotaDashboard`
- **Affected functions:** `QuotaEnforcer.consume/3`, `QuotaResetter.reset_user/2`, `QuotaAuditor.flag_abusers/2`, `QuotaDashboard.usage_report/1`
- **Short explanation:** The quota tracking Agent is directly accessed by four different modules, each independently reading or writing the buckets and violations maps without delegating to a single owner, making the internal data format implicitly shared.

```elixir
defmodule QuotaAgent do
  @moduledoc "Shared Agent tracking API quota usage per user."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          buckets: %{},
          violations: [],
          reset_log: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because QuotaEnforcer directly calls Agent.get and
# Agent.update to check and decrement per-user quota buckets, owning the internal
# bucket map format and mutation semantics without any centralised owner module.
defmodule QuotaEnforcer do
  @moduledoc "Enforces rate limits on API requests per user."

  require Logger

  @default_limit 1000
  @window_seconds 3600

  def consume(agent, user_id, cost \\ 1) do
    now = DateTime.utc_now()

    bucket = Agent.get(agent, fn state -> Map.get(state.buckets, user_id) end)

    bucket =
      case bucket do
        nil ->
          %{user_id: user_id, remaining: @default_limit, limit: @default_limit,
            window_start: now, window_end: DateTime.add(now, @window_seconds, :second)}

        b ->
          if DateTime.compare(b.window_end, now) == :lt do
            %{b | remaining: b.limit, window_start: now, window_end: DateTime.add(now, @window_seconds, :second)}
          else
            b
          end
      end

    if bucket.remaining < cost do
      violation = %{user_id: user_id, at: now, requested: cost, available: bucket.remaining}

      Agent.update(agent, fn state ->
        %{
          state
          | buckets: Map.put(state.buckets, user_id, bucket),
            violations: [violation | state.violations]
        }
      end)

      {:error, :rate_limit_exceeded}
    else
      updated = %{bucket | remaining: bucket.remaining - cost}

      Agent.update(agent, fn state ->
        %{state | buckets: Map.put(state.buckets, user_id, updated)}
      end)

      Logger.debug("Consumed #{cost} quota for #{user_id}, remaining: #{updated.remaining}")
      {:ok, updated.remaining}
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because QuotaResetter directly calls Agent.update to
# reset individual user buckets and append reset log entries, independently
# manipulating both the buckets map and reset_log list inside the Agent.
defmodule QuotaResetter do
  @moduledoc "Manually resets quota buckets for users on plan upgrades or support actions."

  require Logger

  def reset_user(agent, user_id, new_limit \\ nil) do
    case Agent.get(agent, fn state -> Map.get(state.buckets, user_id) end) do
      nil ->
        {:error, :user_not_found}

      bucket ->
        limit = new_limit || bucket.limit
        now = DateTime.utc_now()

        Agent.update(agent, fn state ->
          reset_entry = %{user_id: user_id, previous_remaining: bucket.remaining, new_limit: limit, reset_at: now}

          updated_bucket = %{
            bucket
            | remaining: limit,
              limit: limit,
              window_start: now,
              window_end: DateTime.add(now, 3600, :second)
          }

          %{
            state
            | buckets: Map.put(state.buckets, user_id, updated_bucket),
              reset_log: [reset_entry | state.reset_log]
          }
        end)

        Logger.info("Reset quota for user #{user_id} to #{limit}")
        :ok
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because QuotaAuditor directly calls Agent.get to read
# the violations list and Agent.update to tag abuser records, another module that
# independently accesses the Agent's internal violations list structure.
defmodule QuotaAuditor do
  @moduledoc "Identifies and flags users who repeatedly violate quotas."

  require Logger

  @abuse_threshold 5

  def flag_abusers(agent, window_minutes \\ 60) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_minutes * 60, :second)

    recent_violations =
      Agent.get(agent, fn state ->
        Enum.filter(state.violations, fn v -> DateTime.compare(v.at, cutoff) == :gt end)
      end)

    offenders =
      recent_violations
      |> Enum.group_by(& &1.user_id)
      |> Enum.filter(fn {_uid, vs} -> length(vs) >= @abuse_threshold end)
      |> Enum.map(fn {uid, vs} -> {uid, length(vs)} end)

    Enum.each(offenders, fn {user_id, count} ->
      Agent.update(agent, fn state ->
        flag = %{user_id: user_id, violation_count: count, flagged_at: DateTime.utc_now()}
        %{state | violations: [flag | state.violations]}
      end)

      Logger.warning("Flagged abuser #{user_id} with #{count} violations in #{window_minutes}m")
    end)

    {:ok, length(offenders)}
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because QuotaDashboard directly calls Agent.get to read
# and summarise the raw bucket map, coupling dashboard queries to the Agent's internal
# bucket record structure.
defmodule QuotaDashboard do
  @moduledoc "Displays quota consumption summaries for operations teams."

  def usage_report(agent) do
    Agent.get(agent, fn state ->
      buckets = Map.values(state.buckets)
      total_users = length(buckets)
      exhausted = Enum.count(buckets, &(&1.remaining == 0))
      low = Enum.count(buckets, &(&1.remaining > 0 and &1.remaining / &1.limit < 0.1))

      avg_remaining =
        if total_users > 0 do
          buckets |> Enum.map(& &1.remaining) |> Enum.sum() |> Kernel./(total_users) |> Float.round(1)
        else
          0.0
        end

      %{
        total_users: total_users,
        exhausted_users: exhausted,
        low_quota_users: low,
        avg_remaining: avg_remaining,
        total_violations: length(state.violations),
        generated_at: DateTime.utc_now()
      }
    end)
  end
end
# VALIDATION: SMELL END
```
