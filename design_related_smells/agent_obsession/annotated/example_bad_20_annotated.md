# Annotated Example — Agent Obsession

| Field | Value |
|---|---|
| **Smell name** | Agent Obsession |
| **Expected smell location** | Multiple modules: `SessionTracker`, `SessionAudit`, `SessionPolicy`, `SessionReport` |
| **Affected functions** | `SessionTracker.record_login/3`, `SessionAudit.flag_suspicious/2`, `SessionPolicy.enforce_timeout/2`, `SessionReport.summary/1` |
| **Short explanation** | Four authentication-related modules each directly call `Agent` functions to read and mutate shared session state. No single module owns or encapsulates the agent; every module reaches into it freely, spreading interaction responsibility across the system. |

```elixir
defmodule SessionTracker do
  @moduledoc """
  Records user login events into the shared session agent.
  """

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{sessions: %{}, flagged: [], timeout_policy: 30, report_data: []}
    end)
    pid
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionTracker directly calls Agent.update/2 to write
  # into the shared session state, making this module one of many scattered owners of the agent,
  # rather than delegating all agent access to a single encapsulating module.
  def record_login(pid, user_id, metadata) do
    Agent.update(pid, fn state ->
      session = %{
        user_id: user_id,
        logged_in_at: DateTime.utc_now(),
        ip: metadata[:ip],
        device: metadata[:device],
        active: true
      }
      updated = Map.put(state.sessions, user_id, session)
      %{state | sessions: updated}
    end)
  end

  def record_logout(pid, user_id) do
    Agent.update(pid, fn state ->
      updated = Map.update(state.sessions, user_id, %{}, fn s -> %{s | active: false} end)
      %{state | sessions: updated}
    end)
  end

  def active_sessions(pid) do
    Agent.get(pid, fn state ->
      Enum.filter(state.sessions, fn {_k, v} -> v.active end)
    end)
  end
  # VALIDATION: SMELL END
end

defmodule SessionAudit do
  @moduledoc """
  Flags suspicious sessions based on login metadata analysis.
  """

  @suspicious_countries ["XX", "ZZ"]

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionAudit also directly mutates the agent state
  # via Agent.update/2, adding another module to the set of uncontrolled agent writers.
  # The `flagged` field format is assumed implicitly by all modules.
  def flag_suspicious(pid, user_id) do
    session = Agent.get(pid, fn state -> Map.get(state.sessions, user_id) end)

    cond do
      is_nil(session) ->
        {:error, :session_not_found}

      session[:country] in @suspicious_countries ->
        Agent.update(pid, fn state ->
          entry = %{user_id: user_id, reason: :suspicious_country, at: DateTime.utc_now()}
          %{state | flagged: [entry | state.flagged]}
        end)
        {:ok, :flagged}

      true ->
        {:ok, :clean}
    end
  end

  def list_flagged(pid) do
    Agent.get(pid, fn state -> state.flagged end)
  end
  # VALIDATION: SMELL END
end

defmodule SessionPolicy do
  @moduledoc """
  Enforces timeout policies on active sessions.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionPolicy is a third module that directly reads
  # and writes the agent using Agent.get/2 and Agent.update/2. The timeout_policy field is
  # accessed here without a centralized contract, creating tight implicit coupling.
  def enforce_timeout(pid, now \\ DateTime.utc_now()) do
    timeout = Agent.get(pid, fn state -> state.timeout_policy end)

    Agent.update(pid, fn state ->
      updated_sessions =
        Map.new(state.sessions, fn {uid, session} ->
          expired =
            session.active &&
              DateTime.diff(now, session.logged_in_at, :minute) > timeout

          {uid, %{session | active: !expired}}
        end)

      %{state | sessions: updated_sessions}
    end)
  end

  def set_timeout(pid, minutes) when is_integer(minutes) and minutes > 0 do
    Agent.update(pid, fn state -> %{state | timeout_policy: minutes} end)
  end
  # VALIDATION: SMELL END
end

defmodule SessionReport do
  @moduledoc """
  Produces authentication session summary reports.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionReport is a fourth module directly calling
  # Agent.get/2 to read the full agent state. The internal structure of the agent is now
  # implicitly shared across all four modules, making any structural change risky and expensive.
  def summary(pid) do
    state = Agent.get(pid, fn s -> s end)

    total = map_size(state.sessions)
    active = Enum.count(state.sessions, fn {_k, v} -> v.active end)
    flagged = length(state.flagged)

    %{
      total_sessions: total,
      active_sessions: active,
      inactive_sessions: total - active,
      flagged_sessions: flagged,
      current_timeout_policy_minutes: state.timeout_policy,
      generated_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END
end
```
