# Annotated Bad Example 02

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@jwt_secret` defined at the top of `Auth.TokenProvider`
- **Affected function(s):** `generate_token/2`, `verify_token/1`
- **Short explanation:** `Application.fetch_env!/2` is invoked in the module body to populate `@jwt_secret`. Because module attributes are resolved during compilation — before the Application Environment is available — this can produce warnings or crashes at compile-time.

---

```elixir
defmodule Auth.TokenProvider do
  @moduledoc """
  Issues and validates JWT tokens used to authenticate API requests.
  Tokens carry a subject claim (user ID), an expiry, and an optional
  set of permission scopes.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is evaluated in the
  # VALIDATION: module body at compile-time. The Application Environment for :auth may
  # VALIDATION: not be loaded when the compiler processes this attribute, leading to a
  # VALIDATION: warning or an ArgumentError crash during compilation.
  @jwt_secret Application.fetch_env!(:auth, :jwt_secret)
  # VALIDATION: SMELL END

  @token_ttl_seconds 3_600
  @algorithm "HS256"

  @type token_claims :: %{
          sub: String.t(),
          exp: integer(),
          iat: integer(),
          scopes: [String.t()]
        }

  @doc """
  Generates a signed JWT for the given `user_id` and optional `scopes`.

  Tokens are valid for #{@token_ttl_seconds} seconds from issuance.

  ## Examples

      iex> Auth.TokenProvider.generate_token("user_42", ["read", "write"])
      {:ok, "eyJhbGci..."}
  """
  @spec generate_token(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def generate_token(user_id, scopes \\ []) when is_binary(user_id) do
    now = System.system_time(:second)

    claims = %{
      "sub" => user_id,
      "iat" => now,
      "exp" => now + @token_ttl_seconds,
      "scopes" => scopes
    }

    case sign_claims(claims) do
      {:ok, token} ->
        Logger.debug("Generated JWT for user_id=#{user_id} scopes=#{inspect(scopes)}")
        {:ok, token}

      {:error, reason} ->
        Logger.error("Failed to generate JWT for user_id=#{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Verifies a JWT string and returns the decoded claims if valid.

  Returns `{:error, :expired}` if the token has passed its `exp` claim,
  `{:error, :invalid_signature}` if the signature does not match, or
  `{:error, :malformed}` for any other structural issue.

  ## Examples

      iex> Auth.TokenProvider.verify_token("eyJhbGci...")
      {:ok, %{"sub" => "user_42", "scopes" => ["read", "write"]}}
  """
  @spec verify_token(String.t()) ::
          {:ok, token_claims()} | {:error, :expired | :invalid_signature | :malformed}
  def verify_token(raw_token) when is_binary(raw_token) do
    with {:ok, claims} <- decode_and_verify(raw_token),
         :ok <- check_expiry(claims) do
      Logger.debug("JWT verification succeeded sub=#{claims["sub"]}")
      {:ok, claims}
    else
      {:error, :expired} = err ->
        Logger.info("JWT expired for token=#{String.slice(raw_token, 0, 20)}...")
        err

      {:error, reason} = err ->
        Logger.warning("JWT verification failed reason=#{inspect(reason)}")
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sign_claims(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => @algorithm, "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header}.#{payload}"
    signature = :crypto.mac(:hmac, :sha256, @jwt_secret, signing_input) |> Base.url_encode64(padding: false)
    {:ok, "#{signing_input}.#{signature}"}
  rescue
    e -> {:error, e}
  end

  defp decode_and_verify(raw_token) do
    case String.split(raw_token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        signing_input = "#{header_b64}.#{payload_b64}"
        expected_sig = :crypto.mac(:hmac, :sha256, @jwt_secret, signing_input) |> Base.url_encode64(padding: false)

        if Plug.Crypto.secure_compare(expected_sig, signature_b64) do
          claims = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
          {:ok, claims}
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :malformed}
end
```
