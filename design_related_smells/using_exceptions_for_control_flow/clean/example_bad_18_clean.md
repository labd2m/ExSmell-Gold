```elixir
defmodule Security.TokenClaims do
  @moduledoc "Parsed claims extracted from a validated JWT."

  @enforce_keys [:subject, :issuer, :issued_at, :expires_at, :scopes]
  defstruct [:subject, :issuer, :issued_at, :expires_at, :scopes, :metadata]
end

defmodule Security.IssuerRegistry do
  @moduledoc "Known token issuers and their public verification keys."

  @issuers %{
    "auth.myapp.com" => "public_key_alpha",
    "auth.partner.io" => "public_key_beta",
    "internal.services" => "public_key_gamma"
  }

  def find(issuer), do: Map.fetch(@issuers, issuer)
  def known?(issuer), do: Map.has_key?(@issuers, issuer)
  def all, do: Map.keys(@issuers)
end

defmodule Security.JwtDecoder do
  @moduledoc "Simulates JWT decoding and signature verification."

  def decode("malformed." <> _), do: {:error, :malformed}

  def decode(token) when is_binary(token) do
    parts = String.split(token, ".")

    if length(parts) != 3 do
      {:error, :malformed}
    else
      [_header, payload, _sig] = parts

      claims = %{
        "sub" => "user_#{:rand.uniform(999)}",
        "iss" => "auth.myapp.com",
        "iat" => System.os_time(:second) - 3600,
        "exp" => System.os_time(:second) + 3600,
        "scopes" => ["read", "write"]
      }

      {:ok, {claims, payload}}
    end
  end

  def verify_signature(_payload, _key), do: :ok
end

defmodule Security.TokenValidator do
  @moduledoc """
  Validates JWTs for API authentication. Checks structural integrity,
  issuer trust, expiry, and cryptographic signature.
  """

  alias Security.{IssuerRegistry, JwtDecoder, TokenClaims}
  require Logger

  def validate(raw_token, opts \\ []) when is_binary(raw_token) do
    _require_scopes = Keyword.get(opts, :require_scopes, [])

    case JwtDecoder.decode(raw_token) do
      {:error, :malformed} ->
        raise RuntimeError,
          message: "Token is malformed — expected three dot-separated Base64 segments"

      {:ok, {claims, payload}} ->
        issuer = Map.get(claims, "iss")

        unless IssuerRegistry.known?(issuer) do
          raise RuntimeError,
            message:
              "Token issuer '#{issuer}' is not trusted. " <>
                "Trusted issuers: #{Enum.join(IssuerRegistry.all(), ", ")}"
        end

        exp = Map.get(claims, "exp", 0)
        now = System.os_time(:second)

        if exp <= now do
          expired_ago = now - exp

          raise RuntimeError,
            message: "Token expired #{expired_ago} seconds ago"
        end

        {:ok, key} = IssuerRegistry.find(issuer)

        case JwtDecoder.verify_signature(payload, key) do
          :error ->
            raise RuntimeError, message: "Token signature verification failed"

          :ok ->
            token_claims = %TokenClaims{
              subject: Map.get(claims, "sub"),
              issuer: issuer,
              issued_at: Map.get(claims, "iat"),
              expires_at: exp,
              scopes: Map.get(claims, "scopes", [])
            }

            Logger.debug("Token validated for subject=#{token_claims.subject}")
            token_claims
        end
    end
  end
end

defmodule Security.ApiAuthPlug do
  @moduledoc """
  Plug that validates the Bearer token on every incoming API request.
  Sets the current user claims in the connection assigns on success,
  or halts the connection with a 401 on failure.
  """

  alias Security.TokenValidator
  require Logger

  def init(opts), do: opts

  def call(%{req_headers: headers} = conn, opts) do
    required_scopes = Keyword.get(opts, :require_scopes, [])

    case List.keyfind(headers, "authorization", 0) do
      nil ->
        halt_unauthorized(conn, "Missing Authorization header")

      {"authorization", "Bearer " <> token} ->
        # Client forced to use try/rescue because TokenValidator.validate/2
        # raises on all authentication failure paths instead of returning
        # {:error, reason}.
        try do
          claims = TokenValidator.validate(token, require_scopes: required_scopes)
          Map.put(conn, :assigns, Map.put(conn[:assigns] || %{}, :current_claims, claims))
        rescue
          e in RuntimeError ->
            Logger.info("Auth rejected: #{e.message}")
            halt_unauthorized(conn, e.message)
        end

      _ ->
        halt_unauthorized(conn, "Malformed Authorization header")
    end
  end

  defp halt_unauthorized(conn, reason) do
    Map.merge(conn, %{
      status: 401,
      resp_body: Jason.encode!(%{error: "unauthorized", detail: reason}),
      halted: true
    })
  end
end
```
