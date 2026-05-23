# Annotated Example 03: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Auth.SessionBuilder.build_session_claims/1`
- **Affected Function(s)**: `build_session_claims/1`
- **Explanation**: `build_session_claims/1` exclusively uses data and functions from the
  `User` module (`User.role/1`, `User.permissions/1`, `User.organization_id/1`,
  `User.subscription_tier/1`, `User.display_name/1`, `User.avatar_url/1`) plus direct
  struct fields. `SessionBuilder` contributes no logic of its own to this function,
  making it a better fit for the `User` module.

## Code

```elixir
defmodule Auth.SessionBuilder do
  alias Auth.{Token, Session}
  alias Accounts.User

  @session_ttl_seconds 86_400
  @refresh_ttl_seconds 604_800

  @doc """
  Creates a new authenticated session for a verified user.
  Returns the session record along with signed access and refresh tokens.
  """
  def create_session(user_id, metadata \\ %{}) do
    user = User.get!(user_id)

    with :ok <- check_account_status(user),
         claims <- build_session_claims(user),
         {:ok, access_token} <- Token.sign(claims, ttl: @session_ttl_seconds),
         {:ok, refresh_token} <- Token.generate_refresh(user_id),
         {:ok, session} <-
           Session.create(%{
             user_id: user_id,
             access_token_hash: Token.hash(access_token),
             refresh_token_hash: Token.hash(refresh_token),
             ip_address: metadata[:ip_address],
             user_agent: metadata[:user_agent],
             expires_at:
               DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)
           }) do
      {:ok,
       %{session: session, access_token: access_token, refresh_token: refresh_token}}
    end
  end

  @doc """
  Refreshes an existing session using a valid refresh token.
  """
  def refresh_session(refresh_token) do
    with {:ok, user_id} <- Token.verify_refresh(refresh_token),
         user <- User.get!(user_id),
         :ok <- check_account_status(user) do
      create_session(user_id)
    end
  end

  @doc """
  Revokes a session by its ID, immediately invalidating the tokens.
  """
  def revoke_session(session_id) do
    with {:ok, session} <- Session.get(session_id) do
      Session.revoke(session)
    end
  end

  @doc """
  Lists all active sessions for a given user.
  """
  def list_active_sessions(user_id) do
    Session.list_active(user_id)
  end

  @doc """
  Revokes all sessions for a user, forcing a full sign-out.
  """
  def revoke_all_sessions(user_id) do
    user_id
    |> Session.list_active()
    |> Enum.each(&Session.revoke/1)
  end

  defp check_account_status(user) do
    cond do
      not is_nil(user.locked_at) -> {:error, :account_locked}
      not is_nil(user.deactivated_at) -> {:error, :account_deactivated}
      not user.email_verified -> {:error, :email_not_verified}
      true -> :ok
    end
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because build_session_claims/1 exclusively uses data and
  # VALIDATION: functions from the User module: User.role/1, User.permissions/1,
  # VALIDATION: User.organization_id/1, User.subscription_tier/1, User.display_name/1,
  # VALIDATION: User.avatar_url/1, and direct fields from the user struct.
  # VALIDATION: SessionBuilder contributes no logic of its own to this function, making it
  # VALIDATION: a better fit for the User module.
  defp build_session_claims(user) do
    role = User.role(user)
    permissions = User.permissions(user)
    org_id = User.organization_id(user)
    tier = User.subscription_tier(user)
    display_name = User.display_name(user)
    avatar_url = User.avatar_url(user)

    %{
      sub: user.id,
      email: user.email,
      name: display_name,
      picture: avatar_url,
      role: role,
      permissions: permissions,
      org_id: org_id,
      subscription_tier: tier,
      email_verified: user.email_verified,
      iat: DateTime.to_unix(DateTime.utc_now()),
      exp:
        DateTime.to_unix(
          DateTime.add(DateTime.utc_now(), @session_ttl_seconds, :second)
        )
    }
  end
  # VALIDATION: SMELL END
end
```
