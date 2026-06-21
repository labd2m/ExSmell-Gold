```elixir
defmodule MyApp.Accounts.ImpersonationSession do
  @moduledoc """
  Allows admin users to impersonate customer accounts for support
  purposes. Impersonation sessions are time-limited, fully audited, and
  automatically expire without manual action. An impersonating admin
  retains their own identity in the audit log regardless of which
  customer account they are acting as.

  All impersonation actions are recorded in the `audit_log` table via
  `MyApp.Compliance.AuditLogger` before any state change is made, so
  the audit record exists even if a subsequent step fails.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{User, ImpersonationToken}
  alias MyApp.Compliance.AuditLogger

  import Ecto.Query, warn: false

  @session_ttl_minutes 30
  @token_bytes 24

  @type admin_id :: String.t()
  @type target_user_id :: String.t()

  @doc """
  Creates an impersonation session for `admin_id` acting as `target_user_id`.
  Returns `{:ok, {raw_token, session}}` on success.
  Returns `{:error, :target_is_admin}` when attempting to impersonate another admin.
  """
  @spec start(admin_id(), target_user_id(), String.t()) ::
          {:ok, {binary(), ImpersonationToken.t()}}
          | {:error, :target_is_admin}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def start(admin_id, target_user_id, reason)
      when is_binary(admin_id) and is_binary(target_user_id) and is_binary(reason) do
    AuditLogger.log(
      %{id: admin_id, type: :admin},
      "impersonation.started",
      %{id: target_user_id, type: "user"},
      %{reason: reason}
    )

    with {:ok, target} <- fetch_impersonatable(target_user_id),
         {:ok, token} <- create_token(admin_id, target.id, reason) do
      raw = token.raw_token
      {:ok, {raw, Map.delete(token, :raw_token)}}
    end
  end

  @doc """
  Verifies `raw_token` and returns `{admin_id, target_user}` when valid.
  Returns `{:error, :invalid}` for expired, missing, or consumed tokens.
  """
  @spec verify(binary()) ::
          {:ok, {admin_id(), User.t()}} | {:error, :invalid}
  def verify(raw_token) when is_binary(raw_token) do
    hashed = hash(raw_token)

    query =
      from t in ImpersonationToken,
        join: u in User, on: u.id == t.target_user_id,
        where: t.token_hash == ^hashed and t.expires_at > ^DateTime.utc_now() and is_nil(t.used_at),
        select: {t, u}

    case Repo.one(query) do
      nil -> {:error, :invalid}
      {token, user} -> {:ok, {token.admin_id, user}}
    end
  end

  @doc "Consumes `raw_token`, preventing reuse."
  @spec end_session(binary()) :: :ok
  def end_session(raw_token) when is_binary(raw_token) do
    hashed = hash(raw_token)

    Repo.update_all(
      from(t in ImpersonationToken, where: t.token_hash == ^hashed),
      set: [used_at: DateTime.utc_now()]
    )

    :ok
  end

  @spec fetch_impersonatable(target_user_id()) ::
          {:ok, User.t()} | {:error, :not_found} | {:error, :target_is_admin}
  defp fetch_impersonatable(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      %User{role: :admin} -> {:error, :target_is_admin}
      user -> {:ok, user}
    end
  end

  @spec create_token(admin_id(), target_user_id(), String.t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  defp create_token(admin_id, target_user_id, reason) do
    raw = :crypto.strong_rand_bytes(@token_bytes)
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_minutes, :minute)

    result =
      %ImpersonationToken{}
      |> ImpersonationToken.changeset(%{
        admin_id: admin_id,
        target_user_id: target_user_id,
        token_hash: hash(raw),
        reason: reason,
        expires_at: expires_at
      })
      |> Repo.insert()

    case result do
      {:ok, token} -> {:ok, Map.put(token, :raw_token, raw)}
      {:error, cs} -> {:error, cs}
    end
  end

  @spec hash(binary()) :: binary()
  defp hash(data), do: :crypto.hash(:sha256, data)
end
```
