# Annotated Example 05

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `AuthHandler.handle/1`
- **Affected function(s):** `handle/1`
- **Short explanation:** The `handle/1` function groups three fundamentally different authentication operations — validating an API key, issuing a JWT session token for a login, and revoking an OAuth token — into a single multi-clause function. These operations have different security contexts, input validation rules, and side effects, and they should be separate, clearly named functions.

---

```elixir
defmodule AuthHandler do
  @moduledoc """
  Processes authentication and authorization requests for the platform API.
  """

  alias AuthHandler.{
    ApiKeyValidationRequest,
    LoginRequest,
    OAuthRevocationRequest,
    Repo,
    TokenStore,
    JWTCodec,
    RateLimiter
  }

  @max_login_attempts 5
  @jwt_ttl_seconds 3600

  @doc """
  Handles an authentication request.

  ## Examples

      iex> AuthHandler.handle(%ApiKeyValidationRequest{key: "sk_live_abc123"})
      {:ok, %{valid: true, scopes: [:read, :write]}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because the three clauses perform unrelated
  # authentication operations: API key validation (stateless lookup), JWT issuance
  # for a login (stateful session creation with rate limiting), and OAuth token
  # revocation (external token lifecycle management). Each has a distinct contract,
  # security implication, and caller context, making them poor candidates for
  # a single multi-clause function.

  def handle(%ApiKeyValidationRequest{key: key, required_scopes: required_scopes}) do
    with {:ok, api_key_record} <- Repo.find_api_key(key),
         true <- api_key_record.active,
         true <- DateTime.compare(api_key_record.expires_at, DateTime.utc_now()) == :gt,
         true <- Enum.all?(required_scopes, &(&1 in api_key_record.scopes)) do
      {:ok, %{valid: true, scopes: api_key_record.scopes, key_id: api_key_record.id}}
    else
      {:error, :not_found} -> {:error, :invalid_key}
      false -> {:error, :key_expired_or_insufficient_scope}
    end
  end

  # issues a JWT token for a successful user login
  def handle(%LoginRequest{email: email, password: password, ip_address: ip}) do
    with :ok <- RateLimiter.check(ip, :login, limit: @max_login_attempts, window_seconds: 300),
         {:ok, user} <- Repo.find_user_by_email(email),
         true <- user.active,
         :ok <- Argon2.verify_pass(password, user.password_hash) do
      claims = %{
        sub: user.id,
        email: user.email,
        roles: user.roles,
        iat: System.system_time(:second),
        exp: System.system_time(:second) + @jwt_ttl_seconds
      }

      token = JWTCodec.encode!(claims)
      RateLimiter.reset(ip, :login)

      {:ok, %{token: token, expires_in: @jwt_ttl_seconds, user_id: user.id}}
    else
      {:error, :rate_limited} -> {:error, :too_many_attempts}
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  # revokes an OAuth 2.0 access or refresh token
  def handle(%OAuthRevocationRequest{token: token, token_type_hint: hint, client_id: client_id}) do
    token_type = hint || detect_token_type(token)

    case TokenStore.revoke(token, token_type, client_id) do
      :ok ->
        :telemetry.execute([:auth, :oauth, :token_revoked], %{count: 1}, %{
          client_id: client_id,
          token_type: token_type
        })

        {:ok, :revoked}

      {:error, :not_found} ->
        {:ok, :already_invalid}

      {:error, :client_mismatch} ->
        {:error, :unauthorized_client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # VALIDATION: SMELL END

  defp detect_token_type(token) do
    case String.length(token) do
      len when len > 100 -> :access_token
      _ -> :refresh_token
    end
  end
end
```
