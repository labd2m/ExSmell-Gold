# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@secret_key` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `sign/2`, `verify/1`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to resolve the JWT secret and store it in the module attribute `@secret_key`. The application environment is not loaded during compilation, so this raises warnings or a hard `ArgumentError`. Even if it resolves, the secret is baked into the compiled beam file, preventing rotation without a full recompile.

---

```elixir
defmodule Auth.TokenService do
  @moduledoc """
  Issues and verifies signed JWT-style tokens for authenticated sessions.
  Tokens carry a user identifier, a set of scopes, and an expiry timestamp.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 runs during
  # VALIDATION: module compilation. If :auth_service has not been loaded yet,
  # VALIDATION: Elixir raises an ArgumentError. Additionally, the resolved
  # VALIDATION: secret string is frozen in the module's compiled bytecode,
  # VALIDATION: so rotating the secret at runtime has no effect on tokens
  # VALIDATION: signed or verified after the last compilation.
  @secret_key Application.fetch_env!(:auth_service, :jwt_secret)
  # VALIDATION: SMELL END

  @token_ttl_seconds 3_600
  @algorithm "HS256"
  @issuer "auth_service"

  @type scope :: :read | :write | :admin
  @type claims :: %{
          sub: String.t(),
          scopes: [scope()],
          iat: integer(),
          exp: integer(),
          iss: String.t()
        }

  @spec sign(String.t(), [scope()]) :: {:ok, String.t()} | {:error, :signing_failed}
  def sign(user_id, scopes) when is_binary(user_id) and is_list(scopes) do
    now = System.system_time(:second)

    claims = %{
      sub: user_id,
      scopes: Enum.map(scopes, &Atom.to_string/1),
      iat: now,
      exp: now + @token_ttl_seconds,
      iss: @issuer
    }

    case encode_and_sign(claims) do
      {:ok, token} ->
        Logger.debug("Token issued", user_id: user_id, exp: claims.exp)
        {:ok, token}

      {:error, reason} ->
        Logger.error("Token signing failed", user_id: user_id, reason: inspect(reason))
        {:error, :signing_failed}
    end
  end

  @spec verify(String.t()) ::
          {:ok, claims()} | {:error, :expired | :invalid_signature | :malformed}
  def verify(token) when is_binary(token) do
    with {:ok, {header_b64, claims_b64, sig_b64}} <- split_token(token),
         {:ok, claims} <- decode_claims(claims_b64),
         :ok <- check_expiry(claims),
         :ok <- verify_signature(header_b64, claims_b64, sig_b64) do
      {:ok, atomise_claims(claims)}
    else
      {:error, :expired} ->
        Logger.info("Token rejected: expired")
        {:error, :expired}

      {:error, :invalid_signature} ->
        Logger.warning("Token rejected: invalid signature")
        {:error, :invalid_signature}

      {:error, _} ->
        {:error, :malformed}
    end
  end

  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def refresh(token) do
    with {:ok, claims} <- verify(token) do
      sign(claims.sub, claims.scopes)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp encode_and_sign(claims) do
    header = Base.url_encode64(~s({"alg":"#{@algorithm}","typ":"JWT"}), padding: false)
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = hmac_sign("#{header}.#{payload}")
    {:ok, "#{header}.#{payload}.#{signature}"}
  rescue
    e -> {:error, e}
  end

  defp split_token(token) do
    case String.split(token, ".") do
      [h, c, s] -> {:ok, {h, c, s}}
      _ -> {:error, :malformed}
    end
  end

  defp decode_claims(claims_b64) do
    with {:ok, json} <- Base.url_decode64(claims_b64, padding: false),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :malformed}

  defp verify_signature(header_b64, claims_b64, sig_b64) do
    expected = hmac_sign("#{header_b64}.#{claims_b64}")
    if Plug.Crypto.secure_compare(expected, sig_b64), do: :ok, else: {:error, :invalid_signature}
  end

  defp hmac_sign(data) do
    :crypto.mac(:hmac, :sha256, @secret_key, data)
    |> Base.url_encode64(padding: false)
  end

  defp atomise_claims(claims) do
    %{
      sub: claims["sub"],
      scopes: Enum.map(claims["scopes"] || [], &String.to_existing_atom/1),
      iat: claims["iat"],
      exp: claims["exp"],
      iss: claims["iss"]
    }
  end
end
```
