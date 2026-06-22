```elixir
defmodule Integrations.OAuthClient do
  @moduledoc """
  Manages OAuth 2.0 authorization-code flows for third-party integrations.
  Handles token exchange, refresh, and revocation. Tokens are persisted via
  the Integration context. Refresh tokens are used transparently when an
  access token has expired so callers always receive a usable credential.
  """

  require Logger

  alias Integrations.TokenStore

  @type provider :: :google | :github | :slack | :salesforce
  @type tokens :: %{access_token: String.t(), refresh_token: String.t() | nil, expires_at: DateTime.t() | nil}
  @type exchange_result :: {:ok, tokens()} | {:error, :exchange_failed | :invalid_code}

  @doc """
  Exchanges an authorization code for access and refresh tokens.
  Persists the received tokens and returns them to the caller.
  """
  @spec exchange_code(provider(), String.t(), String.t()) :: exchange_result()
  def exchange_code(provider, code, redirect_uri)
      when is_atom(provider) and is_binary(code) and is_binary(redirect_uri) do
    config = provider_config(provider)

    body = URI.encode_query(%{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      client_id: config[:client_id],
      client_secret: config[:client_secret]
    })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HTTPoison.post(config[:token_url], body, headers, recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, token_map} ->
            tokens = parse_tokens(token_map)
            TokenStore.upsert(provider, tokens)
            {:ok, tokens}

          _ ->
            {:error, :exchange_failed}
        end

      {:ok, %{status_code: 400}} ->
        {:error, :invalid_code}

      _ ->
        {:error, :exchange_failed}
    end
  end

  @doc """
  Returns a fresh access token for `provider`, refreshing via the stored
  refresh token when the current access token is expired or absent.
  """
  @spec fresh_token(provider()) ::
          {:ok, String.t()} | {:error, :not_connected | :refresh_failed}
  def fresh_token(provider) when is_atom(provider) do
    case TokenStore.fetch(provider) do
      {:error, :not_found} ->
        {:error, :not_connected}

      {:ok, %{access_token: token, expires_at: exp} = tokens} ->
        if expired?(exp) do
          refresh(provider, tokens)
        else
          {:ok, token}
        end
    end
  end

  @doc "Revokes stored tokens for `provider` and removes them from the store."
  @spec revoke(provider()) :: :ok
  def revoke(provider) when is_atom(provider) do
    case TokenStore.fetch(provider) do
      {:ok, %{access_token: token}} ->
        attempt_revocation(provider, token)
        TokenStore.delete(provider)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp refresh(provider, %{refresh_token: nil}), do: {:error, :refresh_failed}

  defp refresh(provider, %{refresh_token: refresh_token}) do
    config = provider_config(provider)

    body = URI.encode_query(%{
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: config[:client_id],
      client_secret: config[:client_secret]
    })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HTTPoison.post(config[:token_url], body, headers, recv_timeout: 10_000) do
      {:ok, %{status_code: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, token_map} ->
            tokens = parse_tokens(token_map)
            TokenStore.upsert(provider, tokens)
            {:ok, tokens.access_token}

          _ ->
            {:error, :refresh_failed}
        end

      _ ->
        {:error, :refresh_failed}
    end
  end

  defp attempt_revocation(provider, token) do
    config = provider_config(provider)
    if revoke_url = config[:revoke_url] do
      body = URI.encode_query(%{token: token})
      HTTPoison.post(revoke_url, body, [{"Content-Type", "application/x-www-form-urlencoded"}])
    end
  rescue
    _ -> :ok
  end

  defp parse_tokens(map) do
    expires_in = Map.get(map, "expires_in")
    expires_at = if expires_in, do: DateTime.add(DateTime.utc_now(), expires_in, :second), else: nil

    %{
      access_token: Map.fetch!(map, "access_token"),
      refresh_token: Map.get(map, "refresh_token"),
      expires_at: expires_at
    }
  end

  defp expired?(nil), do: false
  defp expired?(exp), do: DateTime.compare(DateTime.utc_now(), exp) != :lt

  defp provider_config(provider) do
    Application.fetch_env!(:my_app, {:oauth, provider})
  end
end
```
