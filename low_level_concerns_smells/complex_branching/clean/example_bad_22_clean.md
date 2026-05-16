```elixir
defmodule Auth.OAuthClient do
  @moduledoc """
  Manages OAuth2 authorisation code exchange and token refresh flows
  for third-party provider integrations (Google, GitHub, Slack, etc.).
  """

  require Logger

  alias Auth.{OAuthToken, User}

  @token_endpoint_timeout 10_000
  @clock_skew_seconds 30

  def exchange_code(provider, code, redirect_uri) do
    provider_config = get_provider_config!(provider)

    params = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      client_id: provider_config.client_id,
      client_secret: provider_config.client_secret
    }

    HTTPClient.post(provider_config.token_url, params, timeout: @token_endpoint_timeout)
    |> handle_token_response()
  end

  def refresh_token(provider, refresh_token) do
    provider_config = get_provider_config!(provider)

    params = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: provider_config.client_id,
      client_secret: provider_config.client_secret
    }

    HTTPClient.post(provider_config.token_url, params, timeout: @token_endpoint_timeout)
    |> handle_token_response()
  end

  def store_token(user_id, provider, token_data) do
    with {:ok, user} <- User.fetch(user_id) do
      OAuthToken.upsert(%{
        user_id: user.id,
        provider: provider,
        access_token: token_data.access_token,
        refresh_token: token_data[:refresh_token],
        expires_at: token_expiry(token_data[:expires_in]),
        scope: token_data[:scope]
      })
    end
  end

  def valid_token?(%OAuthToken{expires_at: nil}), do: true

  def valid_token?(%OAuthToken{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp handle_token_response(response) do
    case response do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok, %{
          access_token: token,
          refresh_token: body["refresh_token"],
          expires_in: body["expires_in"],
          token_type: body["token_type"],
          scope: body["scope"]
        }}

      {:ok, %{status: 400, body: %{"error" => "invalid_grant", "error_description" => desc}}} ->
        Logger.warning("OAuth invalid grant: #{desc}")
        {:error, {:invalid_grant, desc}}

      {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

      {:ok, %{status: 400, body: %{"error" => "invalid_client"}}} ->
        Logger.error("OAuth client credentials rejected by provider")
        {:error, :invalid_client}

      {:ok, %{status: 400, body: %{"error" => "invalid_request", "error_description" => desc}}} ->
        {:error, {:invalid_request, desc}}

      {:ok, %{status: 400, body: %{"error" => "unsupported_grant_type"}}} ->
        {:error, :unsupported_grant_type}

      {:ok, %{status: 400, body: %{"error" => error}}} ->
        Logger.warning("OAuth 400 error: #{error}")
        {:error, {:oauth_error, error}}

      {:ok, %{status: 401}} ->
        Logger.error("OAuth provider rejected authentication")
        {:error, :unauthorized}

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = extract_retry_after(headers)
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: 500}} ->
        Logger.error("OAuth provider internal server error")
        {:error, :provider_error}

      {:ok, %{status: 503}} ->
        Logger.warning("OAuth provider temporarily unavailable")
        {:error, :service_unavailable}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected OAuth response status: #{status}")
        {:error, {:unexpected_status, status}}

      {:error, :timeout} ->
        Logger.warning("OAuth token request timed out")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("OAuth HTTP client error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp token_expiry(nil), do: nil

  defp token_expiry(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in - @clock_skew_seconds, :second)
  end

  defp extract_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, v} -> String.to_integer(v)
      nil -> 60
    end
  end

  defp get_provider_config!(provider) do
    Application.fetch_env!(:auth, :"oauth_#{provider}")
  end
end
```
