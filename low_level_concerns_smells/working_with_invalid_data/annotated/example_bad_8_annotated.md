# Code Smell: Working with invalid data

- **Smell name:** Working with invalid data
- **Expected smell location:** `issue_token/2`, where `expires_in_seconds` is taken from external options without validation and forwarded to `TokenSigner.sign/2`
- **Affected function(s):** `issue_token/2`, `build_claims/3`
- **Short explanation:** `expires_in_seconds` is extracted from a caller-supplied keyword list with no type or range check. It is passed directly into `build_claims/3` and then used in an arithmetic expression (`System.system_time(:second) + expires_in_seconds`) and forwarded to the `TokenSigner` library. If the caller provides a string, nil, or atom, the error will manifest deep inside the signer or the arithmetic operation, giving no hint that the fault is an unvalidated expiry at the token issuance boundary.

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

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `expires_in_seconds` is read from
  # the caller-supplied `opts` keyword list without any validation. The value
  # flows directly into `build_claims/3` where it is used in the arithmetic
  # expression `now + expires_in_seconds`. If the caller passes a binary,
  # nil, or an atom, the crash will happen inside `build_claims/3` or inside
  # `TokenSigner.sign/2`, far from the entry point, with a misleading
  # ArithmeticError that does not point back to the unvalidated option.
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
  # VALIDATION: SMELL END

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
