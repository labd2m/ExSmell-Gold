```elixir
defmodule MyApp.Auth.OAuthClient do
  @moduledoc """
  Handles OAuth 2.0 authorization code exchange and token refresh
  against multiple identity providers (Google, GitHub, Microsoft).
  """

  require Logger

  alias MyApp.Auth.{TokenStore, SessionManager, ScopeValidator}

  @token_endpoint_google "https://oauth2.googleapis.com/token"
  @token_endpoint_github "https://github.com/login/oauth/access_token"
  @token_endpoint_microsoft "https://login.microsoftonline.com/common/oauth2/v2.0/token"
  @http_timeout_ms 8_000

  @spec exchange_code(String.t(), map()) ::
          {:ok, map()} | {:error, atom() | map()}
  def exchange_code(provider, params) do
    endpoint = resolve_endpoint(provider)
    client_id = Application.fetch_env!(:my_app, :"#{provider}_client_id")
    client_secret = Application.fetch_env!(:my_app, :"#{provider}_client_secret")

    form_body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        code: params.code,
        redirect_uri: params.redirect_uri,
        client_id: client_id,
        client_secret: client_secret
      })

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    Logger.info("Exchanging OAuth code for provider=#{provider}")

    case HTTPoison.post(endpoint, form_body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parsed = Jason.decode!(body)

        cond do
          is_nil(parsed["access_token"]) ->
            Logger.error("OAuth exchange: access_token missing from 200 response provider=#{provider}")
            {:error, :missing_access_token}

          not ScopeValidator.all_granted?(parsed["scope"], params[:required_scopes]) ->
            Logger.warning("OAuth exchange: insufficient scopes granted provider=#{provider}")
            {:error, {:insufficient_scopes, parsed["scope"]}}

          Map.has_key?(parsed, "refresh_token") ->
            token_data = %{
              provider: provider,
              access_token: parsed["access_token"],
              refresh_token: parsed["refresh_token"],
              expires_in: parsed["expires_in"],
              scope: parsed["scope"],
              token_type: parsed["token_type"]
            }

            TokenStore.save(params.user_id, token_data)
            Logger.info("OAuth exchange success with refresh token provider=#{provider} user=#{params.user_id}")
            {:ok, token_data}

          true ->
            token_data = %{
              provider: provider,
              access_token: parsed["access_token"],
              refresh_token: nil,
              expires_in: parsed["expires_in"],
              scope: parsed["scope"],
              token_type: parsed["token_type"]
            }

            TokenStore.save(params.user_id, token_data)
            Logger.info("OAuth exchange success without refresh token provider=#{provider} user=#{params.user_id}")
            {:ok, token_data}
        end

      {:ok, %HTTPoison.Response{status_code: 400, body: body}} ->
        parsed = Jason.decode!(body)

        case parsed["error"] do
          "invalid_grant" ->
            Logger.warning("OAuth exchange: authorization code expired or already used provider=#{provider}")
            {:error, :code_expired}

          "invalid_request" ->
            Logger.error("OAuth exchange: malformed request provider=#{provider} detail=#{parsed["error_description"]}")
            {:error, :invalid_request}

          "redirect_uri_mismatch" ->
            Logger.error("OAuth exchange: redirect_uri mismatch provider=#{provider}")
            {:error, :redirect_uri_mismatch}

          other ->
            Logger.error("OAuth exchange: bad request provider=#{provider} error=#{other}")
            {:error, {:bad_request, parsed}}
        end

      {:ok, %HTTPoison.Response{status_code: 401, body: _body}} ->
        Logger.error("OAuth exchange: invalid client credentials provider=#{provider}")
        {:error, :invalid_client}

      {:ok, %HTTPoison.Response{status_code: 403}} ->
        Logger.error("OAuth exchange: access forbidden provider=#{provider}")
        {:error, :forbidden}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warning("OAuth exchange: rate limited by provider=#{provider}")
        {:error, :provider_rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("OAuth exchange: provider server error status=#{status} provider=#{provider}")
        {:error, :provider_unavailable}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.error("OAuth exchange: unexpected status=#{status} provider=#{provider} body=#{body}")
        {:error, {:unexpected_response, status}}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("OAuth exchange: request timed out provider=#{provider}")
        {:error, :provider_timeout}

      {:error, %HTTPoison.Error{reason: :nxdomain}} ->
        Logger.error("OAuth exchange: DNS resolution failed provider=#{provider}")
        {:error, :dns_failure}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("OAuth exchange: network error provider=#{provider} reason=#{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @spec refresh_token(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def refresh_token(provider, refresh_token) do
    endpoint = resolve_endpoint(provider)
    client_id = Application.fetch_env!(:my_app, :"#{provider}_client_id")
    client_secret = Application.fetch_env!(:my_app, :"#{provider}_client_secret")

    form_body =
      URI.encode_query(%{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}, {"Accept", "application/json"}]

    case HTTPoison.post(endpoint, form_body, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %HTTPoison.Response{status_code: 400}} ->
        {:error, :refresh_token_invalid}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Token refresh network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  # Private helpers

  defp resolve_endpoint("google"), do: @token_endpoint_google
  defp resolve_endpoint("github"), do: @token_endpoint_github
  defp resolve_endpoint("microsoft"), do: @token_endpoint_microsoft
  defp resolve_endpoint(p), do: raise(ArgumentError, "Unknown provider: #{p}")
end
```
