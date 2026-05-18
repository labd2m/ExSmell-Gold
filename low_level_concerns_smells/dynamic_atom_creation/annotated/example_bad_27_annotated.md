# Annotated Example — Code Smell

## Metadata

- **Smell name:** Dynamic atom creation
- **Expected smell location:** `decode_role/1` function
- **Affected function(s):** `decode_role/1`
- **Short explanation:** The function converts a role string received from a JWT token payload into an atom using `String.to_atom/1`. JWT payloads originate from external clients and can carry arbitrary string values, making this an uncontrolled source of atom creation that can exhaust the BEAM atom table.

---

```elixir
defmodule Auth.TokenVerifier do
  @moduledoc """
  Verifies and decodes JWT access tokens issued by the authentication service.
  Extracts claims and constructs a structured session for downstream use.
  """

  require Logger

  alias Auth.{KeyStore, SessionStore, AuditLog}

  @token_ttl_seconds 3_600
  @valid_algorithms ["RS256", "RS384"]

  @spec verify(String.t()) :: {:ok, Auth.Session.t()} | {:error, atom()}
  def verify(raw_token) when is_binary(raw_token) do
    with {:ok, %{"alg" => alg} = header} <- decode_header(raw_token),
         :ok <- validate_algorithm(alg),
         {:ok, public_key} <- KeyStore.fetch_signing_key(header["kid"]),
         {:ok, claims} <- verify_signature(raw_token, public_key),
         :ok <- validate_expiry(claims),
         {:ok, session} <- build_session(claims) do
      AuditLog.record(:token_verified, session.user_id)
      {:ok, session}
    else
      {:error, reason} = err ->
        Logger.warning("Token verification failed", reason: inspect(reason))
        err
    end
  end

  def verify(_), do: {:error, :invalid_token_format}

  defp decode_header(token) do
    case String.split(token, ".") do
      [header_b64 | _] ->
        with {:ok, json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, map} <- Jason.decode(json) do
          {:ok, map}
        else
          _ -> {:error, :malformed_header}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp validate_algorithm(alg) when alg in @valid_algorithms, do: :ok
  defp validate_algorithm(_), do: {:error, :unsupported_algorithm}

  defp verify_signature(token, public_key) do
    case JOSE.JWT.verify(public_key, token) do
      {true, %JOSE.JWT{fields: claims}, _} -> {:ok, claims}
      {false, _, _} -> {:error, :invalid_signature}
    end
  end

  defp validate_expiry(%{"exp" => exp}) do
    now = System.system_time(:second)
    if exp > now, do: :ok, else: {:error, :token_expired}
  end

  defp validate_expiry(_), do: {:error, :missing_expiry}

  defp build_session(claims) do
    with {:ok, user_id} <- fetch_claim(claims, "sub"),
         {:ok, email} <- fetch_claim(claims, "email"),
         {:ok, role} <- decode_role(claims["role"]),
         {:ok, scopes} <- parse_scopes(claims["scope"]) do
      session = %Auth.Session{
        user_id: user_id,
        email: email,
        role: role,
        scopes: scopes,
        issued_at: claims["iat"],
        expires_at: claims["exp"]
      }

      {:ok, session}
    end
  end

  defp fetch_claim(claims, key) do
    case Map.get(claims, key) do
      nil -> {:error, {:missing_claim, key}}
      val -> {:ok, val}
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is called with a
  # value extracted directly from a JWT claim. JWT tokens are supplied by
  # clients and may contain arbitrary role strings, allowing unlimited atom
  # creation that can exhaust the BEAM atom table.
  defp decode_role(nil), do: {:error, :missing_role}

  defp decode_role(role) when is_binary(role) do
    {:ok, String.to_atom(role)}
  end
  # VALIDATION: SMELL END

  defp decode_role(_), do: {:error, :invalid_role}

  defp parse_scopes(nil), do: {:ok, []}

  defp parse_scopes(scope_string) when is_binary(scope_string) do
    scopes =
      scope_string
      |> String.split(" ", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, scopes}
  end

  defp parse_scopes(_), do: {:ok, []}
end
```
