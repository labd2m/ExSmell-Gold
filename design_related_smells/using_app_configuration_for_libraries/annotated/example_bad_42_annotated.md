# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `JwtLib.sign/2` and `JwtLib.verify/1`
- **Affected function(s):** `sign/2`, `verify/1`
- **Short explanation:** The library fetches `:secret_key`, `:expiry_seconds`, and `:algorithm` from the global `Application Environment` instead of receiving them as parameters. This prevents dependent applications from issuing tokens with different TTLs for different purposes (e.g., a short-lived access token vs. a long-lived refresh token) without altering global config.

```elixir
defmodule JwtLib do
  @moduledoc """
  A minimal JWT signing and verification library for Elixir applications.
  Supports HS256 and HS512 HMAC algorithms.

  Configuration (config/config.exs):

      config :jwt_lib,
        secret_key: "super_secret_signing_key",
        expiry_seconds: 3600,
        algorithm: :hs256
  """

  require Logger

  @supported_algorithms [:hs256, :hs512]

  @doc """
  Signs a map of claims and returns a compact JWT string.
  Standard claims (`iat`, `exp`) are automatically appended.
  """
  @spec sign(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def sign(claims, _opts \\ []) when is_map(claims) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library fetches :secret_key,
    # :expiry_seconds, and :algorithm from the global Application Environment
    # rather than accepting them as call-site options. An application that needs
    # short-lived access tokens (e.g., 5 minutes) and long-lived refresh tokens
    # (e.g., 30 days) in the same codebase cannot use this library for both
    # without constantly rewriting global config, breaking reusability.
    secret = Application.fetch_env!(:jwt_lib, :secret_key)
    expiry = Application.fetch_env!(:jwt_lib, :expiry_seconds)
    algorithm = Application.fetch_env!(:jwt_lib, :algorithm)
    # VALIDATION: SMELL END

    unless algorithm in @supported_algorithms do
      raise ArgumentError, "Unsupported algorithm: #{inspect(algorithm)}"
    end

    now = System.os_time(:second)
    full_claims = Map.merge(claims, %{"iat" => now, "exp" => now + expiry})

    header = build_header(algorithm)
    payload = encode_json(full_claims)

    header_b64 = base64_encode(header)
    payload_b64 = base64_encode(payload)

    signing_input = "#{header_b64}.#{payload_b64}"
    signature = compute_signature(algorithm, secret, signing_input)

    {:ok, "#{signing_input}.#{signature}"}
  end

  @doc """
  Verifies a JWT string and returns the decoded claims if valid.
  Checks signature integrity and token expiry.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify(token) when is_binary(token) do
    secret = Application.fetch_env!(:jwt_lib, :secret_key)
    algorithm = Application.fetch_env!(:jwt_lib, :algorithm)

    case String.split(token, ".") do
      [header_b64, payload_b64, signature] ->
        signing_input = "#{header_b64}.#{payload_b64}"
        expected_sig = compute_signature(algorithm, secret, signing_input)

        if secure_compare(expected_sig, signature) do
          with {:ok, claims} <- decode_json(base64_decode(payload_b64)),
               :ok <- check_expiry(claims) do
            {:ok, claims}
          end
        else
          {:error, "Invalid token signature"}
        end

      _ ->
        {:error, "Malformed token: expected 3 segments"}
    end
  end

  @doc """
  Decodes a JWT without verifying its signature. Use with caution.
  """
  @spec decode_unverified(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_unverified(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload_b64, _sig] ->
        decode_json(base64_decode(payload_b64))

      _ ->
        {:error, "Malformed token"}
    end
  end

  @doc """
  Returns true if the token's `exp` claim is in the future.
  """
  @spec expired?(String.t()) :: boolean()
  def expired?(token) when is_binary(token) do
    case decode_unverified(token) do
      {:ok, %{"exp" => exp}} -> System.os_time(:second) >= exp
      _ -> true
    end
  end

  # --- Private helpers ---

  defp build_header(:hs256), do: Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"})
  defp build_header(:hs512), do: Jason.encode!(%{"alg" => "HS512", "typ" => "JWT"})

  defp encode_json(map), do: Jason.encode!(map)

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      _ -> {:error, "Failed to decode JWT segment"}
    end
  end

  defp base64_encode(data), do: Base.url_encode64(data, padding: false)
  defp base64_decode(data), do: Base.url_decode64!(data, padding: false)

  defp compute_signature(:hs256, secret, input) do
    :crypto.mac(:hmac, :sha256, secret, input) |> base64_encode()
  end

  defp compute_signature(:hs512, secret, input) do
    :crypto.mac(:hmac, :sha512, secret, input) |> base64_encode()
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and
      :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.os_time(:second) < exp, do: :ok, else: {:error, "Token has expired"}
  end

  defp check_expiry(_), do: {:error, "Token missing exp claim"}
end
```
