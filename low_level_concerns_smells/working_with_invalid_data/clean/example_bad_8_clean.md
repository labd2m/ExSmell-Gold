# example_bad_8_clean

```elixir
defmodule Auth.TokenIssuer do
  @moduledoc """
  Issues signed JWT-style access and refresh tokens for authenticated sessions.
  Handles claim construction, signing, and audit logging.
  """

  alias Auth.TokenSigner
  alias Auth.AuditLogger
  alias Auth.SessionStore

  @access_token_ttl 3_600
  @refresh_token_ttl 604_800
  @issuer "myapp.internal"
  @supported_scopes ~w(read write admin)

  def issue_access_token(user, opts \\ []) do
    issue_token(user, Keyword.put(opts, :type, :access))
  end

  def issue_refresh_token(user, opts \\ []) do
    issue_token(user, Keyword.put(opts, :type, :refresh))
  end

  defp issue_token(user, opts) do
    token_type = Keyword.fetch!(opts, :type)
    default_ttl = if token_type == :access, do: @access_token_ttl, else: @refresh_token_ttl
    expires_in_seconds = Keyword.get(opts, :expires_in, default_ttl)
    scopes = Keyword.get(opts, :scopes, ["read"])

    with {:ok, validated_scopes} <- validate_scopes(scopes),
         {:ok, claims} <- build_claims(user, expires_in_seconds, validated_scopes),
         {:ok, token} <- TokenSigner.sign(claims, token_type),
         :ok <- SessionStore.persist(user.id, token, claims),
         :ok <- AuditLogger.log_token_issued(user.id, token_type, claims.jti) do
      {:ok, %{token: token, expires_in: expires_in_seconds, type: token_type}}
    end
  end

  defp build_claims(user, expires_in_seconds, scopes) do
    now = System.system_time(:second)
    jti = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    claims = %{
      sub: user.id,
      email: user.email,
      roles: user.roles,
      scopes: scopes,
      iss: @issuer,
      iat: now,
      exp: now + expires_in_seconds,
      jti: jti
    }

    {:ok, claims}
  end

  defp validate_scopes(scopes) do
    invalid = Enum.reject(scopes, &(&1 in @supported_scopes))

    case invalid do
      [] -> {:ok, scopes}
      bad -> {:error, {:unsupported_scopes, bad}}
    end
  end
end
```
