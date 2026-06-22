```elixir
defmodule Identity.TokenService do
  @moduledoc """
  Stateless JWT-based token generation and verification service.

  Issues access and refresh tokens signed with a rotating HMAC secret.
  Token payloads carry minimal claims; all authorization attributes are
  resolved at runtime from the database, not embedded in the token.
  """

  @access_token_ttl_seconds 900
  @refresh_token_ttl_seconds 2_592_000

  @type claims :: %{sub: String.t(), jti: String.t(), iat: integer(), exp: integer()}
  @type token_pair :: %{access_token: String.t(), refresh_token: String.t()}

  @type verification_result ::
          {:ok, claims()} | {:error, :expired} | {:error, :invalid_signature} | {:error, :malformed}

  @doc """
  Issues a new access/refresh token pair for the given subject ID.

  Both tokens are signed with HMAC-SHA256 using the configured signing secret.
  """
  @spec issue_token_pair(String.t()) :: {:ok, token_pair()}
  def issue_token_pair(subject_id) when is_binary(subject_id) do
    now = System.system_time(:second)

    access_claims = build_claims(subject_id, now, @access_token_ttl_seconds)
    refresh_claims = build_claims(subject_id, now, @refresh_token_ttl_seconds)

    with {:ok, access_token} <- encode_and_sign(access_claims),
         {:ok, refresh_token} <- encode_and_sign(refresh_claims) do
      {:ok, %{access_token: access_token, refresh_token: refresh_token}}
    end
  end

  @doc """
  Verifies the signature and expiry of a token, returning its claims.

  Returns `{:ok, claims}` for valid, unexpired tokens or a descriptive error.
  """
  @spec verify(String.t()) :: verification_result()
  def verify(token) when is_binary(token) do
    with {:ok, {header_b64, payload_b64, sig_b64}} <- split_token(token),
         :ok <- verify_signature(header_b64, payload_b64, sig_b64),
         {:ok, claims} <- decode_payload(payload_b64),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    end
  end

  defp build_claims(subject_id, now, ttl) do
    %{
      sub: subject_id,
      jti: generate_jti(),
      iat: now,
      exp: now + ttl
    }
  end

  defp encode_and_sign(claims) do
    header = Base.url_encode64(Jason.encode!(%{alg: "HS256", typ: "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    sig = compute_signature("#{header}.#{payload}")

    {:ok, "#{header}.#{payload}.#{sig}"}
  end

  defp split_token(token) do
    case String.split(token, ".") do
      [header, payload, sig] -> {:ok, {header, payload, sig}}
      _ -> {:error, :malformed}
    end
  end

  defp verify_signature(header_b64, payload_b64, provided_sig) do
    expected_sig = compute_signature("#{header_b64}.#{payload_b64}")

    if Plug.Crypto.secure_compare(expected_sig, provided_sig) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp decode_payload(payload_b64) do
    with {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, claims} <- Jason.decode(json, keys: :atoms) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(%{exp: exp}) do
    now = System.system_time(:second)
    if exp > now, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_claims), do: {:error, :malformed}

  defp compute_signature(data) do
    secret = Application.fetch_env!(:identity, :jwt_signing_secret)
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64(padding: false)
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
```
