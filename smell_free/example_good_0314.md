```elixir
defmodule Auth.Jwt.Claims do
  @moduledoc false

  @type t :: %__MODULE__{
          sub: String.t(),
          iss: String.t(),
          aud: String.t(),
          iat: integer(),
          exp: integer(),
          jti: String.t(),
          extra: map()
        }

  defstruct [:sub, :iss, :aud, :iat, :exp, :jti, extra: %{}]

  @spec new(String.t(), pos_integer(), keyword()) :: t()
  def new(subject, ttl_seconds, opts \\ [])
      when is_binary(subject) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    now = System.system_time(:second)

    %__MODULE__{
      sub: subject,
      iss: Keyword.get(opts, :issuer, "myapp"),
      aud: Keyword.get(opts, :audience, "myapp"),
      iat: now,
      exp: now + ttl_seconds,
      jti: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false),
      extra: Keyword.get(opts, :extra, %{})
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{exp: exp}), do: System.system_time(:second) >= exp
end

defmodule Auth.Jwt do
  @moduledoc """
  Issues and verifies HMAC-SHA256 signed JSON Web Tokens.

  Tokens are produced as three Base64url-encoded segments separated by dots.
  Verification checks the signature first to authenticate the token, then
  validates registered claims (expiry, issuer, audience) so that expired or
  misrouted tokens are rejected with a distinct typed reason.
  """

  alias Auth.Jwt.Claims

  @algorithm "HS256"

  @type verify_error ::
          :invalid_format
          | :invalid_signature
          | :token_expired
          | :issuer_mismatch
          | :audience_mismatch

  @spec issue(Claims.t(), binary()) :: String.t()
  def issue(%Claims{} = claims, secret) when is_binary(secret) do
    header = encode_segment(%{"alg" => @algorithm, "typ" => "JWT"})

    payload =
      encode_segment(%{
        "sub" => claims.sub,
        "iss" => claims.iss,
        "aud" => claims.aud,
        "iat" => claims.iat,
        "exp" => claims.exp,
        "jti" => claims.jti
      } |> Map.merge(claims.extra))

    signature = sign("#{header}.#{payload}", secret)
    "#{header}.#{payload}.#{signature}"
  end

  @spec verify(String.t(), binary(), keyword()) ::
          {:ok, Claims.t()} | {:error, verify_error()}
  def verify(token, secret, opts \\ []) when is_binary(token) and is_binary(secret) do
    expected_issuer = Keyword.get(opts, :issuer, "myapp")
    expected_audience = Keyword.get(opts, :audience, "myapp")

    with {:ok, {header_b64, payload_b64, sig_b64}} <- split_token(token),
         :ok <- verify_signature("#{header_b64}.#{payload_b64}", sig_b64, secret),
         {:ok, raw_claims} <- decode_segment(payload_b64),
         {:ok, claims} <- build_claims(raw_claims),
         :ok <- check_expiry(claims),
         :ok <- check_issuer(claims, expected_issuer),
         :ok <- check_audience(claims, expected_audience) do
      {:ok, claims}
    end
  end

  defp split_token(token) do
    case String.split(token, ".") do
      [h, p, s] -> {:ok, {h, p, s}}
      _ -> {:error, :invalid_format}
    end
  end

  defp verify_signature(data, provided_sig, secret) do
    expected = sign(data, secret)

    if :crypto.hash_equals(
         Base.url_decode64!(expected, padding: false),
         Base.url_decode64!(provided_sig, padding: false)
       ) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  defp encode_segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_segment(b64) do
    with {:ok, json} <- Base.url_decode64(b64, padding: false),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp build_claims(%{"sub" => sub, "iss" => iss, "aud" => aud, "iat" => iat, "exp" => exp, "jti" => jti} = raw) do
    known_keys = ~w(sub iss aud iat exp jti)
    extra = Map.drop(raw, known_keys)
    {:ok, %Claims{sub: sub, iss: iss, aud: aud, iat: iat, exp: exp, jti: jti, extra: extra}}
  end

  defp build_claims(_), do: {:error, :invalid_format}

  defp check_expiry(claims), do: if(Claims.expired?(claims), do: {:error, :token_expired}, else: :ok)
  defp check_issuer(%Claims{iss: i}, expected) when i == expected, do: :ok
  defp check_issuer(_, _), do: {:error, :issuer_mismatch}
  defp check_audience(%Claims{aud: a}, expected) when a == expected, do: :ok
  defp check_audience(_, _), do: {:error, :audience_mismatch}

  defp sign(data, secret) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64(padding: false)
  end
end
```
