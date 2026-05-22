# Code Smell: Compile-time Global Configuration

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module body, lines where `@token_secret`, `@token_ttl_seconds`, and `@issuer` are defined
- **Affected function(s):** `generate_token/2`, `verify_token/1`, `build_claims/2`
- **Short explanation:** The module attributes `@token_secret`, `@token_ttl_seconds`, and `@issuer` are set by calling `Application.fetch_env!/2` in the module body. These calls happen at compile time, before the application environment is available, which can cause an `ArgumentError` or a compiler warning. Runtime functions that need these values should read them directly from the application environment instead.

---

```elixir
defmodule Auth.TokenManager do
  @moduledoc """
  Issues and validates signed JWT-style session tokens for
  authenticated platform users.

  Tokens carry a standard set of claims (subject, issuer,
  issued-at, expiry) and are signed with an HMAC-SHA256
  secret drawn from application configuration.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is invoked in
  # VALIDATION: the module body to set module attributes. This runs at compile
  # VALIDATION: time when the application environment is not yet started, which
  # VALIDATION: can raise an ArgumentError (key not found) or a compiler warning.
  # VALIDATION: These values must be fetched at runtime inside each function.
  @token_secret      Application.fetch_env!(:auth, :token_signing_secret)
  @token_ttl_seconds Application.fetch_env!(:auth, :token_ttl_seconds)
  @issuer            Application.fetch_env!(:auth, :token_issuer)
  # VALIDATION: SMELL END

  @algorithm "HS256"

  @type claims :: %{
    sub:  String.t(),
    iss:  String.t(),
    iat:  integer(),
    exp:  integer(),
    role: String.t()
  }

  @type token_result :: {:ok, String.t()} | {:error, atom()}

  @spec generate_token(String.t(), String.t()) :: token_result()
  def generate_token(user_id, role) when is_binary(user_id) and is_binary(role) do
    claims = build_claims(user_id, role)

    case sign_claims(claims) do
      {:ok, token} ->
        Logger.info("Token issued",
          user_id: user_id,
          role: role,
          expires_in: @token_ttl_seconds
        )

        {:ok, token}

      {:error, _reason} = err ->
        Logger.error("Token signing failed", user_id: user_id)
        err
    end
  end

  @spec verify_token(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify_token(token) when is_binary(token) do
    with {:ok, raw_claims}       <- decode_and_verify_signature(token),
         {:ok, validated_claims} <- validate_claims(raw_claims) do
      {:ok, validated_claims}
    else
      {:error, :invalid_signature} ->
        Logger.warn("Token signature mismatch")
        {:error, :unauthorized}

      {:error, :expired} ->
        Logger.info("Expired token presented")
        {:error, :token_expired}

      {:error, reason} ->
        Logger.error("Token validation error", reason: reason)
        {:error, :invalid_token}
    end
  end

  @spec revoke_all_for_user(String.t()) :: :ok
  def revoke_all_for_user(user_id) do
    Logger.info("Revoking all tokens", user_id: user_id)
    Auth.TokenStore.delete_by_subject(user_id)
    :ok
  end

  defp build_claims(user_id, role) do
    now = System.system_time(:second)

    %{
      sub:  user_id,
      iss:  @issuer,
      iat:  now,
      exp:  now + @token_ttl_seconds,
      role: role
    }
  end

  defp sign_claims(claims) do
    header  = Base.url_encode64(~s|{"alg":"#{@algorithm}","typ":"JWT"}|, padding: false)
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    message = "#{header}.#{payload}"
    sig     = :crypto.mac(:hmac, :sha256, @token_secret, message)
              |> Base.url_encode64(padding: false)

    {:ok, "#{message}.#{sig}"}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp decode_and_verify_signature(token) do
    case String.split(token, ".") do
      [header_b64, payload_b64, sig_b64] ->
        message        = "#{header_b64}.#{payload_b64}"
        expected_sig   = :crypto.mac(:hmac, :sha256, @token_secret, message)
                        |> Base.url_encode64(padding: false)

        if Plug.Crypto.secure_compare(sig_b64, expected_sig) do
          claims = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
          {:ok, claims}
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp validate_claims(%{"exp" => exp} = claims) do
    if System.system_time(:second) > exp do
      {:error, :expired}
    else
      {:ok, claims}
    end
  end

  defp validate_claims(_), do: {:error, :missing_expiry}
end
```
