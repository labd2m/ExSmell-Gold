```elixir
defmodule TokenBuilder do
  @moduledoc """
  Library for generating and validating signed authentication tokens.
  Intended for use in authentication services, API gateways, and
  single-sign-on middleware.
  """

  @supported_algorithms ~w(HS256 HS384 HS512)

  @type claims :: %{
          required(:sub) => String.t(),
          required(:iss) => String.t(),
          optional(:role) => String.t(),
          optional(:scope) => [String.t()]
        }

  @type token_result ::
          {:ok, String.t()}
          | {:error, :invalid_claims}
          | {:error, :unsupported_algorithm}

  @doc """
  Generates a signed token for the given subject and claims map.
  Token lifetime and signing algorithm are read from the
  application environment at call time.
  """
  @spec generate(String.t(), claims()) :: token_result()
  def generate(secret, claims) when is_binary(secret) and is_map(claims) do
    with :ok <- validate_claims(claims) do
      ttl = Application.fetch_env!(:token_builder, :token_ttl_seconds)
      algorithm = Application.fetch_env!(:token_builder, :signing_algorithm)

      if algorithm not in @supported_algorithms do
        {:error, :unsupported_algorithm}
      else
        now = System.system_time(:second)

        payload =
          claims
          |> Map.put(:iat, now)
          |> Map.put(:exp, now + ttl)
          |> Map.put(:jti, generate_jti())

        encoded = encode_and_sign(payload, secret, algorithm)
        {:ok, encoded}
      end
    end
  end

  @doc """
  Verifies a token string against the given secret and returns
  the decoded claims if valid.
  """
  @spec verify(String.t(), String.t()) ::
          {:ok, map()} | {:error, :expired} | {:error, :invalid_signature} | {:error, :malformed}
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    with {:ok, header, payload, sig} <- split_token(token),
         :ok <- verify_signature(header, payload, sig, secret),
         {:ok, claims} <- decode_payload(payload),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Decodes a token without verifying the signature (for inspection only)."
  @spec peek_claims(String.t()) :: {:ok, map()} | {:error, :malformed}
  def peek_claims(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] -> decode_payload(payload)
      _ -> {:error, :malformed}
    end
  end

  @doc "Returns true if the token has not yet expired, without verifying signature."
  @spec expired?(String.t()) :: boolean()
  def expired?(token) do
    case peek_claims(token) do
      {:ok, %{"exp" => exp}} -> System.system_time(:second) >= exp
      _ -> true
    end
  end

  # --- Private helpers ---

  defp validate_claims(claims) do
    if Map.has_key?(claims, :sub) and Map.has_key?(claims, :iss) do
      :ok
    else
      {:error, :invalid_claims}
    end
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp encode_and_sign(payload, secret, algorithm) do
    header = Base.url_encode64(~s({"alg":"#{algorithm}","typ":"JWT"}), padding: false)
    body = Base.url_encode64(Jason.encode!(payload), padding: false)
    signing_input = "#{header}.#{body}"
    sig = :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.url_encode64(padding: false)
    "#{signing_input}.#{sig}"
  end

  defp split_token(token) do
    case String.split(token, ".") do
      [h, p, s] -> {:ok, h, p, s}
      _ -> {:error, :malformed}
    end
  end

  defp verify_signature(header, payload, sig, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, "#{header}.#{payload}")
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp decode_payload(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, json} -> Jason.decode(json)
      :error -> {:error, :malformed}
    end
  end

  defp check_expiry(%{"exp" => exp}) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: :ok
end
```
