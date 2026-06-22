# File: `example_good_702.md`

```elixir
defmodule Accounts.ImpersonationGuard do
  @moduledoc """
  Manages admin impersonation sessions, allowing support staff to
  temporarily act on behalf of a user while maintaining a full audit
  trail.

  Impersonation sessions are time-limited and scoped to the admin's
  authenticated session. Every impersonation start, action, and end
  is logged to the audit trail for compliance.
  """

  import Ecto.Query, warn: false

  alias Accounts.{ImpersonationSession, Repo, User}
  alias Audit.Trail

  @default_session_ttl_minutes 30
  @token_bytes 20

  @type admin_id :: Ecto.UUID.t()
  @type target_user_id :: Ecto.UUID.t()
  @type session_token :: String.t()

  @type session_result ::
          {:ok, %{token: session_token(), session: ImpersonationSession.t()}}
          | {:error, atom() | Ecto.Changeset.t()}

  @doc """
  Starts an impersonation session for `admin` acting as `target_user`.

  The admin must have the `:impersonate` permission (checked via the
  access control context). Returns a short-lived session token and
  the session record.
  """
  @spec start(User.t(), User.t(), keyword()) :: session_result()
  def start(%User{} = admin, %User{} = target_user, opts \\ []) do
    ttl_minutes = Keyword.get(opts, :ttl_minutes, @default_session_ttl_minutes)
    reason = Keyword.get(opts, :reason, "")

    with :ok <- verify_impersonation_permission(admin),
         :ok <- verify_not_self(admin, target_user),
         :ok <- verify_not_already_impersonating(admin.id) do
      create_session(admin, target_user, ttl_minutes, reason)
    end
  end

  @doc """
  Resolves a session token to the impersonated user and admin.

  Returns `{:ok, %{admin: User.t(), target_user: User.t()}}` or an error
  if the token is invalid or the session has expired.
  """
  @spec resolve(session_token()) ::
          {:ok, %{admin: User.t(), target_user: User.t()}}
          | {:error, :invalid | :expired}
  def resolve(token) when is_binary(token) do
    token_hash = hash(token)
    now = DateTime.utc_now()

    ImpersonationSession
    |> where([s], s.token_hash == ^token_hash and s.ended_at is nil and s.expires_at > ^now)
    |> preload([:admin, :target_user])
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid}
      session -> {:ok, %{admin: session.admin, target_user: session.target_user}}
    end
  end

  @doc """
  Ends an impersonation session identified by its token.

  Records the end time and logs the session closure to the audit trail.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec end_session(session_token()) :: :ok | {:error, :not_found}
  def end_session(token) when is_binary(token) do
    token_hash = hash(token)

    ImpersonationSession
    |> where([s], s.token_hash == ^token_hash and s.ended_at is nil)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> ImpersonationSession.end_changeset(%{ended_at: DateTime.utc_now()})
        |> Repo.update!()

        Trail.record(
          %{id: session.admin_id, type: :user},
          %{id: session.target_user_id, type: "user"},
          "impersonation_ended",
          %{session_id: session.id}
        )

        :ok
    end
  end

  @doc """
  Returns all active impersonation sessions for audit review.
  """
  @spec active_sessions() :: [ImpersonationSession.t()]
  def active_sessions do
    now = DateTime.utc_now()

    ImpersonationSession
    |> where([s], s.ended_at is nil and s.expires_at > ^now)
    |> preload([:admin, :target_user])
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  defp verify_impersonation_permission(%User{} = admin) do
    if :impersonate in admin.permissions do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp verify_not_self(%User{id: admin_id}, %User{id: target_id}) do
    if admin_id == target_id, do: {:error, :cannot_impersonate_self}, else: :ok
  end

  defp verify_not_already_impersonating(admin_id) do
    now = DateTime.utc_now()
    active = ImpersonationSession
      |> where([s], s.admin_id == ^admin_id and s.ended_at is nil and s.expires_at > ^now)
      |> Repo.exists?()

    if active, do: {:error, :session_already_active}, else: :ok
  end

  defp create_session(admin, target_user, ttl_minutes, reason) do
    token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_minutes * 60, :second)

    attrs = %{
      admin_id: admin.id,
      target_user_id: target_user.id,
      token_hash: hash(token),
      expires_at: expires_at,
      reason: reason
    }

    Repo.transaction(fn ->
      session = attrs |> ImpersonationSession.changeset() |> Repo.insert!()

      Trail.record(
        %{id: admin.id, type: :user},
        %{id: target_user.id, type: "user"},
        "impersonation_started",
        %{session_id: session.id, reason: reason, expires_at: DateTime.to_iso8601(expires_at)}
      )

      %{token: token, session: session}
    end)
  end

  defp hash(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
```
