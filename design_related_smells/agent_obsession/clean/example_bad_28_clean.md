```elixir
defmodule Auth.SessionTracker do
  @moduledoc """
  Registers and tracks active user sessions.
  """

  def start_link() do
    Agent.start_link(fn -> %{sessions: %{}, total_registered: 0} end, name: __MODULE__)
  end

  def register(pid, session) do
    Agent.update(pid, fn state ->
      updated_sessions = Map.put(state.sessions, session.token, session)
      %{state | sessions: updated_sessions, total_registered: state.total_registered + 1}
    end)
  end

  def get_session(pid, token) do
    Agent.get(pid, fn state -> Map.get(state.sessions, token) end)
  end

  def all_sessions(pid) do
    Agent.get(pid, fn state -> Map.values(state.sessions) end)
  end
end

defmodule Auth.SessionAudit do
  @moduledoc """
  Appends audit log entries to each session.
  """

  def log_action(pid, token, action) do
    Agent.update(pid, fn state ->
      session = Map.get(state.sessions, token)

      if session do
        audit_entry = %{action: action, timestamp: DateTime.utc_now()}
        updated_session = Map.update(session, :audit_log, [audit_entry], &[audit_entry | &1])
        updated_sessions = Map.put(state.sessions, token, updated_session)
        %{state | sessions: updated_sessions}
      else
        state
      end
    end)
  end
end

defmodule Auth.SessionExpiry do
  @moduledoc """
  Handles expiration and cleanup of stale sessions.
  """

  def expire_session(pid, token) do
    Agent.update(pid, fn state ->
      updated_sessions = Map.delete(state.sessions, token)
      %{state | sessions: updated_sessions}
    end)
  end

  def purge_expired(pid, max_age_seconds) do
    now = DateTime.utc_now()

    Agent.update(pid, fn state ->
      valid_sessions =
        state.sessions
        |> Enum.filter(fn {_token, session} ->
          diff = DateTime.diff(now, session.created_at, :second)
          diff < max_age_seconds
        end)
        |> Map.new()

      %{state | sessions: valid_sessions}
    end)
  end
end

defmodule Auth.SessionDashboard do
  @moduledoc """
  Provides reporting metrics on active sessions.
  """

  def active_count(pid) do
    Agent.get(pid, fn state -> map_size(state.sessions) end)
  end

  def sessions_by_user(pid) do
    Agent.get(pid, fn state ->
      state.sessions
      |> Map.values()
      |> Enum.group_by(& &1.user_id)
      |> Enum.map(fn {user_id, sessions} -> {user_id, length(sessions)} end)
      |> Map.new()
    end)
  end

  def total_registered(pid) do
    Agent.get(pid, fn state -> state.total_registered end)
  end
end
```
