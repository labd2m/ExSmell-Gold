```elixir
defmodule Platform.Jwt do
  @moduledoc """
  Issues and verifies signed JSON Web Tokens using HMAC-SHA256.

  All operations are pure functions. The signing key and token lifetime
  are passed explicitly per call, making this module suitable for
  multi-tenant scenarios where different keys apply to different issuers.
  """

  @type claims :: %{String.t() => term()}
  @type token :: String.t()
  @type verify_result :: {:ok, claims()} | {:error, :expired | :invalid_signature | :malformed}

  @header_json ~s({"alg":"HS256","typ":"JWT"})
  @header_encoded Base.url_encode64(@header_json, padding: false)

  @doc """
  Issues a signed JWT containing `claims`.

  Adds standard claims: `iat` (issued at) and `exp` (expiry).
  The `sub` claim should be set by the caller.
  """
  @spec issue(claims(), String.t(), pos_integer()) :: token()
  def issue(claims, secret, ttl_seconds \\ 3_600)
      when is_map(claims) and is_binary(secret) and is_integer(ttl_seconds) do
    now = System.os_time(:second)

    full_claims =
      claims
      |> Map.put("iat", now)
      |> Map.put("exp", now + ttl_seconds)

    payload_encoded = full_claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signing_input = @header_encoded <> "." <> payload_encoded
    signature = sign(signing_input, secret)
    signing_input <> "." <> signature
  end

  @doc """
  Verifies a JWT and returns its claims on success.
  Returns `{:error, reason}` when the token is expired, tampered, or malformed.
  """
  @spec verify(token(), String.t()) :: verify_result()
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    with {:ok, {header_enc, payload_enc, sig}} <- split_token(token),
         :ok <- verify_signature("#{header_enc}.#{payload_enc}", sig, secret),
         {:ok, claims} <- decode_claims(payload_enc),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    end
  end

  @doc "Decodes the payload of a JWT without verifying the signature."
  @spec peek_claims(token()) :: {:ok, claims()} | {:error, :malformed}
  def peek_claims(token) when is_binary(token) do
    with {:ok, {_header, payload_enc, _sig}} <- split_token(token),
         {:ok, claims} <- decode_claims(payload_enc) do
      {:ok, claims}
    end
  end

  @doc "Returns the remaining validity in seconds for a verified token."
  @spec remaining_ttl(claims()) :: non_neg_integer()
  def remaining_ttl(%{"exp" => exp}) when is_integer(exp) do
    max(exp - System.os_time(:second), 0)
  end

  def remaining_ttl(_claims), do: 0

  defp split_token(token) do
    case String.split(token, ".") do
      [header, payload, sig] -> {:ok, {header, payload, sig}}
      _ -> {:error, :malformed}
    end
  end

  defp verify_signature(signing_input, received_sig, secret) do
    expected_sig = sign(signing_input, secret)

    if Plug.Crypto.secure_compare(expected_sig, received_sig) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp decode_claims(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if System.os_time(:second) <= exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_claims), do: :ok

  defp sign(data, secret) do
    :crypto.mac(:hmac, :sha256, secret, data)
    |> Base.url_encode64(padding: false)
  end
end
```
