```elixir
defmodule Auth.TokenBuilder do
  @moduledoc """
  Builds and signs JSON Web Tokens for user authentication and
  inter-service authorisation in the platform API.
  """

  @issuer "platform.example.com"
  @default_ttl 3_600
  @algorithm "HS256"


  def sign(claims, secret) do
    JOSE.JWT.sign(
      %{"alg" => @algorithm},
      %{"kty" => "oct", "k" => Base.url_encode64(secret, padding: false)},
      claims
    )
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  def issue(subject, scopes, opts \\ []) do
    require Auth.TokenBuilder

    ttl = Keyword.get(opts, :ttl, @default_ttl)
    claims = Auth.TokenBuilder.build_claims(subject, scopes, ttl)
    secret = Application.fetch_env!(:auth, :jwt_secret)
    token = sign(claims, secret)

    {:ok, %{token: token, claims: claims, expires_in: ttl}}
  end

  def issue_refresh(subject) do
    require Auth.TokenBuilder

    claims =
      Auth.TokenBuilder.build_claims(subject, ["refresh"], @default_ttl * 24 * 30)
      |> Map.put(:type, "refresh")

    secret = Application.fetch_env!(:auth, :jwt_refresh_secret)
    token = sign(claims, secret)

    {:ok, %{refresh_token: token, claims: claims}}
  end

  def verify(token, secret) do
    try do
      {_jws, jwt} =
        JOSE.JWT.verify_strict(
          %{"kty" => "oct", "k" => Base.url_encode64(secret, padding: false)},
          [@algorithm],
          token
        )

      claims = JOSE.JWT.to_map(jwt) |> elem(1)
      now = System.system_time(:second)

      if claims["exp"] > now do
        {:ok, claims}
      else
        {:error, :token_expired}
      end
    rescue
      _ -> {:error, :invalid_token}
    end
  end

  def extract_subject(claims), do: Map.get(claims, "sub")
  def extract_scopes(claims), do: Map.get(claims, "scopes", [])

  def has_scope?(claims, required_scope) do
    required_scope in extract_scopes(claims)
  end

  def ttl_remaining(claims) do
    now = System.system_time(:second)
    max(Map.get(claims, "exp", now) - now, 0)
  end
end
```
