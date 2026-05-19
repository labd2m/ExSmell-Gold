```elixir
defmodule AuthSession do
  @moduledoc """
  Manages user authentication sessions.
  """

  def start do
    Agent.start_link(fn -> %{} end)
  end

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

  def refresh(pid, new_token) do
    Agent.update(pid, fn state ->
      state
      |> Map.put(:token, new_token)
      |> Map.put(:refreshed_at, DateTime.utc_now())
      |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), @token_ttl_seconds))
    end)
    :ok
  end

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

  def list_permissions(pid) do
    Agent.get(pid, fn state -> Map.get(state, :permissions, []) end)
  end
end

defmodule SessionAudit do
  @moduledoc """
  Records access events and produces a session audit trail.
  """

  def log_access(pid, resource) do
    Agent.update(pid, fn state ->
      record = %{resource: resource, accessed_at: DateTime.utc_now()}
      Map.update(state, :access_log, [record], fn log -> [record | log] end)
    end)
    :ok
  end

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
