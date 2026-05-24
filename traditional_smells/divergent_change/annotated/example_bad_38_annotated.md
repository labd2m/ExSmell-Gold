# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `SessionGuard` module (entire module)
- **Affected functions:** `create_session/2`, `validate_session/1`, `revoke_session/1`, `log_activity/3`, `detect_anomaly/2`, `flag_suspicious_session/2`
- **Explanation:** `SessionGuard` combines session token management, activity auditing, and security anomaly detection. These are independent concerns — session token formats/TTL may change with security policies, audit logging may change with compliance requirements, and anomaly detection may change with fraud modeling — each producing unrelated edits to one module.

---

```elixir
defmodule MyApp.SessionGuard do
  @moduledoc """
  Manages user session lifecycle, activity auditing, and anomaly detection
  for the authentication subsystem.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Session, ActivityLog, SuspiciousSession}
  import Ecto.Query

  @session_ttl_seconds 86_400

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because session lifecycle (create/validate/revoke),
  # activity auditing (log_activity), and security anomaly detection
  # (detect_anomaly/flag) are three independent concerns. Security policy changes
  # affect session TTL and token format, compliance changes affect audit logging,
  # and fraud model improvements affect anomaly detection — each driving
  # unrelated changes to this single module.

  ## ── Session Lifecycle ────────────────────────────────────────────────────────

  @doc """
  Creates a new session for a user, returning a signed token.
  """
  def create_session(user_id, metadata \\ %{}) do
    token = :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)

    %Session{}
    |> Session.changeset(%{
      user_id: user_id,
      token_hash: hash_token(token),
      expires_at: expires_at,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      created_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, session} -> {:ok, %{token: token, session_id: session.id, expires_at: expires_at}}
      error -> error
    end
  end

  @doc """
  Validates a session token, returning the associated session if valid.
  """
  def validate_session(token) when is_binary(token) do
    hashed = hash_token(token)

    case Repo.get_by(Session, token_hash: hashed) do
      nil ->
        {:error, :invalid_token}

      %Session{expires_at: exp} = session ->
        if DateTime.compare(DateTime.utc_now(), exp) == :lt do
          {:ok, session}
        else
          {:error, :session_expired}
        end
    end
  end

  @doc """
  Revokes a session immediately, invalidating the token.
  """
  def revoke_session(%Session{} = session) do
    session
    |> Session.changeset(%{revoked_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
  end

  ## ── Activity Auditing ────────────────────────────────────────────────────────

  @doc """
  Records a user action with session context for the audit trail.
  """
  def log_activity(%Session{} = session, action, resource) do
    %ActivityLog{}
    |> ActivityLog.changeset(%{
      session_id: session.id,
      user_id: session.user_id,
      action: action,
      resource: resource,
      ip_address: session.ip_address,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @doc """
  Returns the last N activity log entries for a given user.
  """
  def recent_activity(user_id, limit \\ 50) do
    from(a in ActivityLog,
      where: a.user_id == ^user_id,
      order_by: [desc: a.occurred_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  ## ── Anomaly Detection ────────────────────────────────────────────────────────

  @doc """
  Detects potentially suspicious login patterns for a session.
  Returns a risk score between 0.0 and 1.0.
  """
  def detect_anomaly(%Session{} = session, previous_sessions) do
    ips = Enum.map(previous_sessions, & &1.ip_address) |> MapSet.new()
    agents = Enum.map(previous_sessions, & &1.user_agent) |> MapSet.new()

    new_ip_score = if MapSet.member?(ips, session.ip_address), do: 0.0, else: 0.4
    new_agent_score = if MapSet.member?(agents, session.user_agent), do: 0.0, else: 0.3

    recent_session_count = length(previous_sessions)
    frequency_score = if recent_session_count > 10, do: 0.3, else: 0.0

    Float.round(new_ip_score + new_agent_score + frequency_score, 2)
  end

  @doc """
  Flags a session as suspicious and persists a review record.
  """
  def flag_suspicious_session(%Session{} = session, risk_score) do
    %SuspiciousSession{}
    |> SuspiciousSession.changeset(%{
      session_id: session.id,
      user_id: session.user_id,
      risk_score: risk_score,
      ip_address: session.ip_address,
      flagged_at: DateTime.utc_now(),
      status: :pending_review
    })
    |> Repo.insert()
  end

  # VALIDATION: SMELL END
end
```
