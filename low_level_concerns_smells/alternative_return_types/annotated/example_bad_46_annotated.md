# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Auth.SessionManager.resolve_token/2`, around the `opts[:claims_only]` and `opts[:full]` checks
- **Affected function(s):** `resolve_token/2`
- **Short explanation:** The function returns a `%{sub: string, exp: integer, roles: [string]}` claims map, a full `%Session{}` struct with preloaded user, or just the user's ID integer depending on the options — three incompatible shapes from a single token resolution function.

---

```elixir
defmodule Auth.SessionManager do
  @moduledoc """
  Manages session token issuance, resolution, and revocation.
  Supports JWT-based stateless sessions with optional server-side session records.
  """

  alias Auth.Repo
  alias Auth.Schema.{Session, User}
  alias Auth.JwtCodec

  @token_ttl_seconds 3600
  @refresh_ttl_seconds 86_400

  @doc """
  Issues a new session token pair for a user.
  Returns `{access_token, refresh_token}`.
  """
  def issue_tokens(user_id) do
    claims = %{
      sub: to_string(user_id),
      iat: System.system_time(:second),
      exp: System.system_time(:second) + @token_ttl_seconds,
      roles: fetch_roles(user_id)
    }

    access_token = JwtCodec.sign(claims)

    refresh_claims = %{
      sub: to_string(user_id),
      iat: System.system_time(:second),
      exp: System.system_time(:second) + @refresh_ttl_seconds,
      type: "refresh"
    }

    refresh_token = JwtCodec.sign(refresh_claims)

    record_session(user_id, access_token, refresh_token)

    {access_token, refresh_token}
  end

  @doc """
  Resolves a bearer token to identity information.

  ## Options

    * `:claims_only` — When `true`, returns the raw decoded claims map
      `%{sub: string, exp: integer, roles: [string]}` without hitting the DB.
    * `:full` — When `true`, loads and returns the full `%Session{}` struct
      with the associated `%User{}` preloaded.
    * Default — Returns the integer user ID extracted from the token.

  ## Examples

      iex> resolve_token("eyJhbGc...")
      42

      iex> resolve_token("eyJhbGc...", claims_only: true)
      %{sub: "42", exp: 1719000000, roles: ["admin"]}

      iex> resolve_token("eyJhbGc...", full: true)
      %Session{user: %User{id: 42, ...}, token: "eyJhbGc...", ...}

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the function returns an integer user ID,
  # VALIDATION: a decoded claims map, or a full %Session{} struct with a
  # VALIDATION: preloaded %User{} depending on opts. Every piece of middleware
  # VALIDATION: or plug that calls resolve_token/2 must carry the opts context
  # VALIDATION: to correctly use the return value, spreading coupling everywhere.
  def resolve_token(token, opts \\ []) when is_binary(token) and is_list(opts) do
    case JwtCodec.verify(token) do
      {:ok, claims} ->
        cond do
          opts[:claims_only] == true ->
            claims

          opts[:full] == true ->
            user_id = String.to_integer(claims.sub)

            Session
            |> Repo.get_by!(user_id: user_id, access_token: token)
            |> Repo.preload(:user)

          true ->
            String.to_integer(claims.sub)
        end

      {:error, :expired} ->
        {:error, :token_expired}

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Revokes all active sessions for a user (e.g., on password change).
  """
  def revoke_all(user_id) do
    Session
    |> Repo.all_by(user_id: user_id, revoked: false)
    |> Enum.each(fn session ->
      session
      |> Session.changeset(%{revoked: true, revoked_at: DateTime.utc_now()})
      |> Repo.update!()
    end)

    :ok
  end

  @doc """
  Refreshes an access token using a valid refresh token.
  Returns `{:ok, new_access_token}` or `{:error, reason}`.
  """
  def refresh(refresh_token) do
    case JwtCodec.verify(refresh_token) do
      {:ok, %{type: "refresh", sub: sub}} ->
        user_id = String.to_integer(sub)
        {new_access, _} = issue_tokens(user_id)
        {:ok, new_access}

      {:ok, _} ->
        {:error, :not_a_refresh_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_session(user_id, access_token, refresh_token) do
    %Session{}
    |> Session.changeset(%{
      user_id: user_id,
      access_token: access_token,
      refresh_token: refresh_token,
      revoked: false,
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @token_ttl_seconds, :second)
    })
    |> Repo.insert!()
  end

  defp fetch_roles(user_id) do
    user = Repo.get!(User, user_id)
    user.roles || []
  end
end
```
