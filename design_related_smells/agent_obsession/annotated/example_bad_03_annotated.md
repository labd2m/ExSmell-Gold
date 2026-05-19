# Annotated Example 03 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `AuthSession`, `TokenRefresher`, `PermissionChecker`, and `SessionAudit` all interact directly with the Agent PID
- **Affected functions:** `AuthSession.login/3`, `TokenRefresher.refresh/2`, `PermissionChecker.grant/3`, `SessionAudit.log_access/2`
- **Short explanation:** Session state is stored in an Agent but accessed and modified directly by four separate modules. Each module writes its own shape of data without coordination, making the session state unpredictable and hard to reason about.

---

```elixir
defmodule AuthSession do
  @moduledoc """
  Manages user authentication sessions.
  """

  def start do
    Agent.start_link(fn -> %{} end)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because AuthSession directly calls Agent.update/2
  # to write login information into the shared state. No abstraction layer
  # controls what is written or in what format, so other modules
  # must guess the structure.
  def login(pid, user_id, token) do
    Agent.update(pid, fn _state ->
      %{
        user_id: user_id,
        token: token,
        logged_in_at: DateTime.utc_now(),
        active: true
      }
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def logout(pid) do
    Agent.update(pid, fn state -> Map.put(state, :active, false) end)
    :ok
  end

  def current_user(pid) do
    Agent.get(pid, fn state -> Map.get(state, :user_id) end)
  end

  def active?(pid) do
    Agent.get(pid, fn state -> Map.get(state, :active, false) end)
  end
end

defmodule TokenRefresher do
  @moduledoc """
  Handles token lifecycle and refresh logic for active sessions.
  """

  @token_ttl_seconds 3600

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because TokenRefresher directly manipulates
  # the Agent state by calling Agent.update/2 with its own partial update,
  # merging new token fields into whatever map was put there by AuthSession.
  def refresh(pid, new_token) do
    Agent.update(pid, fn state ->
      state
      |> Map.put(:token, new_token)
      |> Map.put(:refreshed_at, DateTime.utc_now())
      |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), @token_ttl_seconds))
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def token_expired?(pid) do
    Agent.get(pid, fn state ->
      case Map.get(state, :expires_at) do
        nil -> true
        exp -> DateTime.compare(exp, DateTime.utc_now()) == :lt
      end
    end)
  end
end

defmodule PermissionChecker do
  @moduledoc """
  Grants and checks runtime permissions for the session user.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because PermissionChecker directly accesses
  # the Agent through Agent.update/2 and Agent.get/2, embedding a permissions
  # list into the same state map. It has no encapsulation and is tightly
  # coupled to the internal layout set by other modules.
  def grant(pid, permission) when is_atom(permission) do
    Agent.update(pid, fn state ->
      current = Map.get(state, :permissions, [])
      Map.put(state, :permissions, Enum.uniq([permission | current]))
    end)
    :ok
  end

  def has_permission?(pid, permission) do
    Agent.get(pid, fn state ->
      permission in Map.get(state, :permissions, [])
    end)
  end
  # VALIDATION: SMELL END

  def list_permissions(pid) do
    Agent.get(pid, fn state -> Map.get(state, :permissions, []) end)
  end
end

defmodule SessionAudit do
  @moduledoc """
  Records access events and produces a session audit trail.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SessionAudit calls Agent.update/2
  # directly to append audit records into the shared Agent state, mixing
  # a log list into the same map that already holds auth, token, and permission
  # data — none of which it owns.
  def log_access(pid, resource) do
    Agent.update(pid, fn state ->
      record = %{resource: resource, accessed_at: DateTime.utc_now()}
      Map.update(state, :access_log, [record], fn log -> [record | log] end)
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def access_history(pid) do
    Agent.get(pid, fn state -> Map.get(state, :access_log, []) end)
  end

  def report(pid) do
    state = Agent.get(pid, fn s -> s end)
    user = Map.get(state, :user_id, "unknown")
    log = Map.get(state, :access_log, [])
    perms = Map.get(state, :permissions, [])

    IO.puts("Session report for user: #{user}")
    IO.puts("Permissions: #{inspect(perms)}")
    IO.puts("Access events: #{length(log)}")

    Enum.each(log, fn %{resource: r, accessed_at: t} ->
      IO.puts("  - #{r} at #{DateTime.to_iso8601(t)}")
    end)
  end
end
```
