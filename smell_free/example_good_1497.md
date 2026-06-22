```elixir
defmodule Auth.TokenIssuer do
  @moduledoc """
  Issues and verifies signed session tokens for authenticated users.
  Tokens encode claims as a JSON payload and are signed with HMAC-SHA256.
  """

  @token_separator "."
  @default_ttl_seconds 3600

  @type claims :: %{sub: String.t(), role: String.t(), exp: integer()}
  @type token :: String.t()

  @spec issue(String.t(), String.t(), keyword()) :: {:ok, token()} | {:error, String.t()}
  def issue(subject, role, opts \\ [])
      when is_binary(subject) and is_binary(role) do
    with {:ok, secret} <- fetch_secret() do
      ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
      exp = System.system_time(:second) + ttl
      claims = %{sub: subject, role: role, exp: exp}
      {:ok, encode_and_sign(claims, secret)}
    end
  end

  @spec verify(token()) :: {:ok, claims()} | {:error, :invalid_token | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, claims} <- decode_and_verify(token, secret) do
      check_expiry(claims)
    else
      {:error, :invalid_token} = err -> err
      _ -> {:error, :invalid_token}
    end
  end

  @spec encode_and_sign(claims(), binary()) :: token()
  defp encode_and_sign(claims, secret) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = compute_signature(payload, secret)
    Enum.join([payload, signature], @token_separator)
  end

  @spec decode_and_verify(token(), binary()) :: {:ok, claims()} | {:error, :invalid_token}
  defp decode_and_verify(token, secret) do
    case String.split(token, @token_separator, parts: 2) do
      [payload, signature] -> verify_signature(payload, signature, secret)
      _ -> {:error, :invalid_token}
    end
  end

  @spec verify_signature(String.t(), String.t(), binary()) ::
          {:ok, claims()} | {:error, :invalid_token}
  defp verify_signature(payload, given_sig, secret) do
    expected_sig = compute_signature(payload, secret)

    if Plug.Crypto.secure_compare(expected_sig, given_sig) do
      decode_payload(payload)
    else
      {:error, :invalid_token}
    end
  end

  @spec decode_payload(String.t()) :: {:ok, claims()} | {:error, :invalid_token}
  defp decode_payload(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         {:ok, map} <- Jason.decode(raw, keys: :atoms) do
      {:ok, map}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @spec check_expiry(claims()) :: {:ok, claims()} | {:error, :expired}
  defp check_expiry(%{exp: exp} = claims) do
    if System.system_time(:second) <= exp do
      {:ok, claims}
    else
      {:error, :expired}
    end
  end

  defp check_expiry(_), do: {:error, :invalid_token}

  @spec compute_signature(String.t(), binary()) :: String.t()
  defp compute_signature(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  @spec fetch_secret() :: {:ok, binary()} | {:error, String.t()}
  defp fetch_secret do
    case Application.fetch_env(:my_app, :token_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      {:ok, _} -> {:error, "Token secret must be at least 32 bytes"}
      :error -> {:error, "Token secret not configured"}
    end
  end
end
```
