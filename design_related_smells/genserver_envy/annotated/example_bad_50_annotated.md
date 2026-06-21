# Annotated Bad Example 50

- **Smell name:** GenServer Envy
- **Expected smell location:** `SessionStore` module — `Agent`-based process
- **Affected functions:** `encode_session_token/1`, `audit_access/3`, `purge_expired/0`
- **Short explanation:** The `Agent` correctly shares web session state across the request pipeline, but `encode_session_token/1`, `audit_access/3`, and `purge_expired/0` perform isolated work — token serialisation, audit log construction, and a full-store GC sweep — entirely on behalf of the calling process. None of these tasks need to share their results with other processes and should be plain module functions or handled by a `GenServer`, not run inside the Agent's serialized callback queue.

```elixir
defmodule SessionStore do
  @moduledoc """
  Central in-process store for web session state. Holds authenticated
  sessions keyed by session ID across the request-handling pipeline.
  Provides helpers for token encoding, access auditing, and expiry
  management.
  """

  use Agent

  require Logger

  @session_ttl_seconds 86_400
  @signing_secret "s3cr3t_k3y_replace_in_prod"

  @type session :: %{
          session_id: String.t(),
          user_id: String.t(),
          roles: list(String.t()),
          ip_address: String.t(),
          user_agent: String.t(),
          created_at: DateTime.t(),
          last_seen: DateTime.t(),
          metadata: map()
        }

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{sessions: %{}, audit_log: []} end, name: __MODULE__)
  end

  @doc "Creates a new session entry."
  def create_session(%{session_id: sid} = session) do
    Agent.update(__MODULE__, fn state ->
      %{state | sessions: Map.put(state.sessions, sid, session)}
    end)
  end

  @doc "Fetches a session by ID, returning nil if absent."
  def get_session(session_id) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.sessions, session_id)
    end)
  end

  @doc "Refreshes the last_seen timestamp for an active session."
  def touch_session(session_id) do
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :sessions, fn sessions ->
        Map.update(sessions, session_id, nil, fn s ->
          %{s | last_seen: DateTime.utc_now()}
        end)
      end)
    end)
  end

  @doc "Deletes a session on explicit logout."
  def delete_session(session_id) do
    Agent.update(__MODULE__, fn state ->
      %{state | sessions: Map.delete(state.sessions, session_id)}
    end)
  end

  @doc "Returns total number of active sessions."
  def active_count do
    Agent.get(__MODULE__, fn state -> map_size(state.sessions) end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because encode_session_token/1, audit_access/3,
  # and purge_expired/0 perform isolated operations inside Agent callbacks.
  # encode_session_token/1 serialises and signs data purely for the caller.
  # audit_access/3 builds an audit entry that is only appended to state — no
  # other process reads the result. purge_expired/0 performs a full map sweep
  # and mutation useful only to the calling maintenance process. None of these
  # tasks share their output with other processes holding a reference to the
  # Agent; they are isolated side-effectful tasks that belong in a GenServer
  # or a plain functional module, not blocking the Agent's callback queue.

  @doc "Encodes and signs a session as an opaque token — isolated task."
  def encode_session_token(session_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.sessions, session_id) do
        nil ->
          {:error, :not_found}

        session ->
          payload =
            %{
              sid: session.session_id,
              uid: session.user_id,
              roles: session.roles,
              iat: DateTime.to_unix(session.created_at),
              exp: DateTime.to_unix(session.created_at) + @session_ttl_seconds
            }
            |> Jason.encode!()
            |> Base.url_encode64(padding: false)

          signature =
            :crypto.mac(:hmac, :sha256, @signing_secret, payload)
            |> Base.url_encode64(padding: false)

          {:ok, "#{payload}.#{signature}"}
      end
    end)
  end

  @doc "Records an access audit entry for a session — isolated task."
  def audit_access(session_id, action, context \\ %{}) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.sessions, session_id) do
        nil ->
          {{:error, :not_found}, state}

        session ->
          entry = %{
            session_id: session_id,
            user_id: session.user_id,
            action: action,
            ip_address: session.ip_address,
            context: context,
            recorded_at: DateTime.utc_now()
          }

          Logger.info("[SessionStore] Audit: #{inspect(entry)}")

          new_log = [entry | state.audit_log]
          {{:ok, entry}, %{state | audit_log: new_log}}
      end
    end)
  end

  @doc "Removes all sessions that have exceeded the TTL — isolated GC task."
  def purge_expired do
    Agent.get_and_update(__MODULE__, fn state ->
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -@session_ttl_seconds, :second)

      {expired, active} =
        state.sessions
        |> Map.values()
        |> Enum.split_with(fn s ->
          DateTime.compare(s.last_seen, cutoff) == :lt
        end)

      expired_ids = Enum.map(expired, & &1.session_id)

      Logger.info(
        "[SessionStore] Purging #{length(expired_ids)} expired sessions: " <>
          inspect(expired_ids)
      )

      new_sessions =
        active
        |> Enum.map(&{&1.session_id, &1})
        |> Map.new()

      report = %{
        purged_count: length(expired_ids),
        purged_ids: expired_ids,
        remaining: map_size(new_sessions),
        purged_at: now
      }

      {report, %{state | sessions: new_sessions}}
    end)
  end

  # VALIDATION: SMELL END

  @doc "Returns the full audit log (newest first)."
  def get_audit_log do
    Agent.get(__MODULE__, fn state -> state.audit_log end)
  end
end
```
