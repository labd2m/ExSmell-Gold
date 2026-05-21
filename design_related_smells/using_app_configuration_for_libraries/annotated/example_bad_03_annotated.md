# Annotated Example 03

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `TokenGen.generate/1`
- **Affected functions:** `generate/1`
- **Short explanation:** `TokenGen.generate/1` reads `:token_ttl_seconds` and `:signing_algorithm` from the Application Environment. Any application that needs tokens with different TTLs (e.g., short-lived access tokens vs. long-lived refresh tokens) cannot do so through this library without splitting them into different config keys, which defeats the purpose of a reusable library.

```elixir
defmodule TokenGen do
  @moduledoc """
  A lightweight library for generating and verifying signed tokens
  used in authentication flows. Designed to be used in web apps,
  APIs, and internal services.
  """

  require Logger

  @supported_algorithms ~w(HS256 HS384 HS512)

  defmodule Claims do
    @enforce_keys [:sub, :iat, :exp]
    defstruct [:sub, :iat, :exp, :jti, :roles, :meta]
  end

  defmodule TokenError do
    defexception [:message, :reason]
  end

  @doc """
  Generates a signed token for the given subject (user ID or service identity).
  Claims can include additional metadata via the `extra_claims` map.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because token_ttl_seconds and signing_algorithm
  # are fetched from the Application Environment, so every call to generate/1
  # produces tokens with the same TTL and algorithm. An application that needs
  # short-lived access tokens (e.g., 15 min) and long-lived refresh tokens
  # (e.g., 30 days) cannot use this library for both without changing global config.
  def generate(subject, extra_claims \\ %{}) when is_binary(subject) do
    ttl = Application.fetch_env!(:token_gen, :token_ttl_seconds)
    algorithm = Application.fetch_env!(:token_gen, :signing_algorithm)
    secret = Application.fetch_env!(:token_gen, :secret_key)

    unless algorithm in @supported_algorithms do
      raise TokenError, message: "Unsupported algorithm: #{algorithm}", reason: :bad_config
    end

    now = System.system_time(:second)
    jti = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    claims = %Claims{
      sub: subject,
      iat: now,
      exp: now + ttl,
      jti: jti,
      roles: Map.get(extra_claims, "roles", []),
      meta: Map.drop(extra_claims, ["roles"])
    }

    payload = encode_claims(claims)
    signature = sign(payload, secret, algorithm)

    {:ok, "#{payload}.#{signature}"}
  end
  # VALIDATION: SMELL END

  @doc """
  Verifies a token and returns the decoded claims if valid.
  """
  def verify(token) when is_binary(token) do
    secret = Application.fetch_env!(:token_gen, :secret_key)

    with [payload, signature] <- String.split(token, ".", parts: 2),
         true <- valid_signature?(payload, signature, secret),
         {:ok, claims} <- decode_claims(payload),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      false -> {:error, %TokenError{message: "Invalid signature", reason: :bad_signature}}
      {:error, reason} -> {:error, %TokenError{message: inspect(reason), reason: reason}}
      _ -> {:error, %TokenError{message: "Malformed token", reason: :malformed}}
    end
  end

  @doc """
  Returns true if the token is still within its valid window.
  """
  def valid?(token) do
    case verify(token) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # --- Private helpers ---

  defp encode_claims(%Claims{} = claims) do
    claims
    |> Map.from_struct()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_claims(payload) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    end
  end

  defp sign(payload, secret, _algorithm) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp valid_signature?(payload, signature, secret) do
    expected = sign(payload, secret, nil)
    :crypto.hash_equals(Base.url_decode64!(signature, padding: false), Base.url_decode64!(expected, padding: false))
  rescue
    _ -> false
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :missing_exp}
end
```
