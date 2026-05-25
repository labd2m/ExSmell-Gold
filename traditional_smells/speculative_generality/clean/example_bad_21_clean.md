```elixir
defmodule Auth.TokenVerifier do
  @moduledoc """
  Verifies signed JWT-style access tokens issued by the authentication service.

  Tokens are expected to be base64url-encoded and signed with HMAC.
  Verification confirms the signature, checks expiry, and validates required claims.
  """

  alias Auth.{ClaimsValidator, KeyStore}

  @token_separator "."
  @required_claims [:sub, :iat, :exp, :jti]
  @clock_skew_seconds 30

  @spec verify(String.t(), String.t()) ::
          {:ok, map()} | {:error, :invalid_token | :expired | :invalid_claims}
  def verify(token, secret, algorithm \\ :hs256) do
    with {:ok, {header_b64, payload_b64, signature_b64}} <- split_token(token),
         {:ok, header} <- decode_json(header_b64),
         {:ok, payload} <- decode_json(payload_b64),
         :ok <- verify_algorithm_header(header, algorithm),
         :ok <- verify_signature(header_b64, payload_b64, signature_b64, secret, algorithm),
         {:ok, claims} <- extract_claims(payload),
         :ok <- ClaimsValidator.validate_required(claims, @required_claims),
         :ok <- validate_expiry(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_token(token) do
    case String.split(token, @token_separator) do
      [header, payload, signature] -> {:ok, {header, payload, signature}}
      _ -> {:error, :invalid_token}
    end
  end

  defp decode_json(b64) do
    with {:ok, json} <- Base.url_decode64(b64, padding: false),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_algorithm_header(%{"alg" => alg_str}, algorithm) do
    expected = algorithm |> Atom.to_string() |> String.upcase()

    if alg_str == expected do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  defp verify_algorithm_header(_header, _algorithm), do: {:error, :invalid_token}

  defp verify_signature(header_b64, payload_b64, signature_b64, secret, :hs256) do
    signing_input = "#{header_b64}.#{payload_b64}"
    expected_sig = :crypto.mac(:hmac, :sha256, secret, signing_input)
    expected_b64 = Base.url_encode64(expected_sig, padding: false)

    if Plug.Crypto.secure_compare(expected_b64, signature_b64) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  defp verify_signature(_h, _p, _s, _secret, _algorithm), do: {:error, :invalid_token}

  defp extract_claims(payload) when is_map(payload) do
    claims =
      payload
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    {:ok, claims}
  rescue
    ArgumentError -> {:error, :invalid_claims}
  end

  defp extract_claims(_), do: {:error, :invalid_claims}

  defp validate_expiry(%{exp: exp}) do
    now = System.system_time(:second)

    if exp + @clock_skew_seconds > now do
      :ok
    else
      {:error, :expired}
    end
  end

  defp validate_expiry(_claims), do: {:error, :invalid_claims}
end

defmodule Auth.SessionController do
  alias Auth.TokenVerifier

  def authenticate_request(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- TokenVerifier.verify(token, signing_secret()) do
      {:ok, claims}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp signing_secret, do: Application.fetch_env!(:my_app, :token_secret)
  defp get_req_header(conn, header), do: Map.get(conn.req_headers, header, [])
end
```
