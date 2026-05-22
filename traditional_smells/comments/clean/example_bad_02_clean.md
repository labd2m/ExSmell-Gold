```elixir
defmodule AuthService do
  @moduledoc """
  Provides authentication primitives for the platform, including token issuance,
  validation, and session lifecycle management.
  """

  alias AuthService.{TokenStore, UserCredential, SessionLog}
  alias Joken.Signer

  @token_ttl_seconds 3_600
  @refresh_ttl_seconds 86_400
  @issuer "platform.auth"

  @doc """
  Validates raw credentials against stored hashed credentials and returns
  the matching user record on success.
  """
  def authenticate_user(email, password) do
    with {:ok, credential} <- UserCredential.fetch_by_email(email),
         true <- Argon2.verify_pass(password, credential.password_hash) do
      {:ok, credential.user}
    else
      false -> {:error, :invalid_password}
      {:error, reason} -> {:error, reason}
    end
  end

  # issue_access_token/2
  #
  # Generates a signed JWT access token and a paired refresh token for
  # the given user. Both tokens are persisted in the TokenStore so they
  # can be revoked before natural expiry.
  #
  # Parameters:
  #   user   - A %User{} struct with at minimum :id, :email, and :roles fields.
  #   opts   - Keyword list of overrides:
  #              :ttl      - Access token TTL in seconds (default: 3600)
  #              :audience - Intended token audience (default: "api")
  #
  # Returns:
  #   {:ok, %{access_token: binary(), refresh_token: binary(), expires_in: integer()}}
  #   {:error, reason} if signing or persistence fails.
  # — including parameter descriptions, option semantics, and return shape — is expressed
  # via plain comments rather than an @doc attribute, making it invisible to documentation
  # tooling and the IEx help system.
  def issue_access_token(user, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @token_ttl_seconds)
    audience = Keyword.get(opts, :audience, "api")
    now = System.system_time(:second)

    claims = %{
      "sub" => to_string(user.id),
      "email" => user.email,
      "roles" => user.roles,
      "iss" => @issuer,
      "aud" => audience,
      "iat" => now,
      "exp" => now + ttl
    }

    signer = Signer.create("HS256", Application.fetch_env!(:auth_service, :jwt_secret))

    with {:ok, access_token, _} <- Joken.encode_and_sign(claims, signer),
         {:ok, refresh_token} <- generate_refresh_token(user.id),
         :ok <- TokenStore.persist(user.id, access_token, refresh_token, ttl) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_in: ttl
       }}
    end
  end

  @doc """
  Revokes both the access and refresh tokens associated with a session.
  """
  def revoke_session(user_id) do
    with :ok <- TokenStore.revoke_all(user_id),
         {:ok, _} <- SessionLog.record_logout(user_id) do
      :ok
    end
  end

  @doc """
  Validates a JWT access token and returns the embedded claims if valid.
  """
  def validate_token(raw_token) do
    signer = Signer.create("HS256", Application.fetch_env!(:auth_service, :jwt_secret))

    case Joken.verify_and_validate(raw_token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_refresh_token(user_id) do
    token = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @refresh_ttl_seconds, :second)

    case TokenStore.insert_refresh(user_id, token, expires_at) do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end
end
```
