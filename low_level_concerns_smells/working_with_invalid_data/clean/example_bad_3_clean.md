```elixir
defmodule MyApp.Auth.TokenService do
  @moduledoc """
  Issues, validates, and revokes JWT-style access and refresh tokens
  for the authentication subsystem. Tokens are signed with HMAC-SHA256.
  """

  require Logger

  alias MyApp.Auth.{TokenStore, Keyring}
  alias MyApp.Accounts.User

  @access_token_ttl 3_600
  @refresh_token_ttl 2_592_000
  @token_version 1

  @type token_type :: :access | :refresh
  @type issue_opts :: [scope: [String.t()], audience: String.t()]

  @spec issue_token(User.t(), token_type(), issue_opts()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, atom()}
  def issue_token(user, type, opts \\ []) do
    scope = Keyword.get(opts, :scope, ["read"])
    audience = Keyword.get(opts, :audience, "api")

    expires_in =
      case type do
        :access -> @access_token_ttl
        :refresh -> @refresh_token_ttl
      end

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, expires_in, :second)

    claims = %{
      sub: user.id,
      iat: DateTime.to_unix(now),
      exp: DateTime.to_unix(expires_at),
      type: Atom.to_string(type),
      scope: scope,
      aud: audience,
      ver: @token_version
    }

    with {:ok, signing_key} <- Keyring.current_signing_key(),
         {:ok, token} <- sign_claims(claims, signing_key),
         :ok <- TokenStore.persist(token, claims) do
      Logger.info("Token issued for user #{user.id}, type=#{type}, expires_at=#{expires_at}")
      {:ok, %{token: token, expires_at: expires_at, type: type}}
    else
      {:error, reason} = err ->
        Logger.error("Token issuance failed for user #{user.id}: #{inspect(reason)}")
        err
    end
  end

  @spec validate_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_token(raw_token) do
    with {:ok, claims} <- verify_signature(raw_token),
         :ok <- check_expiry(claims),
         :ok <- TokenStore.check_revoked(raw_token) do
      {:ok, claims}
    end
  end

  @spec revoke_token(String.t()) :: :ok | {:error, atom()}
  def revoke_token(raw_token) do
    with {:ok, claims} <- verify_signature(raw_token) do
      TokenStore.revoke(raw_token, claims["exp"])
    end
  end

  @spec revoke_all_for_user(String.t()) :: :ok
  def revoke_all_for_user(user_id) do
    TokenStore.revoke_all(user_id)
  end

  # Private helpers

  defp sign_claims(claims, key) do
    payload = Jason.encode!(claims)
    signature = :crypto.mac(:hmac, :sha256, key, payload) |> Base.url_encode64(padding: false)
    encoded_payload = Base.url_encode64(payload, padding: false)
    {:ok, "v#{@token_version}.#{encoded_payload}.#{signature}"}
  end

  defp verify_signature(token) do
    with [_ver, encoded_payload, _sig] <- String.split(token, "."),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, claims} <- Jason.decode(payload_json) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp check_expiry(%{"exp" => exp}) do
    if DateTime.to_unix(DateTime.utc_now()) < exp do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp check_expiry(_), do: {:error, :missing_expiry}
end
```
