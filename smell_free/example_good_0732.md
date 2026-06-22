```elixir
defmodule Platform.Impersonation do
  @moduledoc """
  Context for service-account impersonation: allows privileged internal actors
  (admins, support tools, background jobs) to act on behalf of a user account
  while maintaining a complete, attributable audit trail.

  Impersonation sessions are time-limited and require explicit justification.
  Every action taken during an impersonation session is tagged with both
  the acting identity and the impersonated account.
  """

  alias Ecto.Multi
  alias Platform.{Repo, AuditLog}
  alias Platform.Impersonation.Session

  @type actor :: %{id: pos_integer(), type: :admin | :service}
  @type impersonated :: %{id: pos_integer()}
  @type session_id :: String.t()

  @session_ttl_minutes 60

  @doc """
  Opens an impersonation session for `actor` to act as `target`.
  Requires a `reason` string for audit purposes.
  Returns `{:ok, session}` or an error.
  """
  @spec open(actor(), impersonated(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def open(%{id: actor_id, type: actor_type}, %{id: target_id}, reason)
      when is_binary(reason) and reason != "" do
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_minutes, :minute)

    attrs = %{
      actor_id: actor_id,
      actor_type: actor_type,
      target_account_id: target_id,
      reason: reason,
      expires_at: expires_at,
      token: generate_token()
    }

    Multi.new()
    |> Multi.insert(:session, Session.changeset(%Session{}, attrs))
    |> Multi.run(:audit, fn _repo, %{session: session} ->
      AuditLog.record(
        %{id: actor_id, type: actor_type},
        :impersonation_started,
        %{id: target_id, type: "account"},
        changes: %{session_id: session.id, reason: reason}
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Validates an impersonation token and returns the active session and target.
  Returns `{:error, :invalid | :expired}` for bad or stale tokens.
  """
  @spec validate_token(String.t()) ::
          {:ok, %{session: Session.t(), actor_id: pos_integer(), target_account_id: pos_integer()}}
          | {:error, :invalid | :expired}
  def validate_token(token) when is_binary(token) do
    case Repo.get_by(Session, token: token) do
      nil ->
        {:error, :invalid}

      %Session{expires_at: exp} when not is_nil(exp) ->
        if DateTime.before?(DateTime.utc_now(), exp) do
          {:ok, %{session: session, actor_id: session.actor_id, target_account_id: session.target_account_id}}
        else
          {:error, :expired}
        end

      session ->
        {:ok, %{session: session, actor_id: session.actor_id, target_account_id: session.target_account_id}}
    end
  end

  @doc """
  Closes an impersonation session and records the termination in the audit log.
  """
  @spec close(session_id(), actor()) :: :ok | {:error, :not_found}
  def close(session_id, actor) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        Repo.delete(session)

        AuditLog.record(
          actor,
          :impersonation_ended,
          %{id: session.target_account_id, type: "account"},
          changes: %{session_id: session_id}
        )

        :ok
    end
  end

  @doc "Lists all active (non-expired) impersonation sessions."
  @spec list_active() :: [Session.t()]
  def list_active do
    import Ecto.Query
    from(s in Session, where: s.expires_at > ^DateTime.utc_now(), order_by: [desc: s.inserted_at])
    |> Repo.all()
  end

  defp generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
```
