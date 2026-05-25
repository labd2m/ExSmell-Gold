```elixir
defmodule Auth.OAuthHandler do
  @moduledoc """
  Handles the OAuth 2.0 callback flow: exchanges the authorization code
  for an access token, fetches the user profile from the provider, and
  upserts the local account record.
  """

  require Logger

  alias Auth.{OAuthClient, Account, IdentityLink, SessionManager}

  @supported_providers [:google, :github, :microsoft]

  @spec handle_callback(atom(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def handle_callback(provider, code, redirect_uri)
      when provider in @supported_providers do
    with {:ok, token_resp} <- OAuthClient.exchange_code(provider, code, redirect_uri),
         {:ok, profile} <- OAuthClient.fetch_profile(provider, token_resp.access_token),
         {:ok, identifier} <- resolve_user_identifier(provider, profile),
         {:ok, account} <- upsert_account(provider, identifier, profile),
         :ok <- IdentityLink.upsert(account.id, provider, profile.provider_user_id),
         {:ok, session} <- SessionManager.create_session(account.id, %{provider: provider}) do
      Logger.info("OAuth login success provider=#{provider} account=#{account.id}")
      {:ok, %{account: account, session_token: session.token, expires_at: session.expires_at}}
    else
      {:error, :provider_error} ->
        Logger.warning("OAuth provider error provider=#{provider}")
        {:error, :provider_error}

      {:error, reason} ->
        Logger.error("OAuth callback failed provider=#{provider}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle_callback(provider, _code, _redirect_uri) do
    Logger.warning("Unsupported OAuth provider: #{inspect(provider)}")
    {:error, :unsupported_provider}
  end

  
  
  
  
  
  
  
  defp resolve_user_identifier(provider, profile) do
    field =
      case provider do
        :google -> :email
        :github -> :email
        :microsoft -> :email
      end

    case Map.fetch(profile, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_identifier}
    end
  end
  

  defp upsert_account(provider, identifier, profile) do
    case Account.find_by_email(identifier) do
      {:ok, existing} ->
        Account.touch_last_login(existing.id, provider)

      {:error, :not_found} ->
        Account.create(%{
          email: identifier,
          display_name: Map.get(profile, :name, identifier),
          avatar_url: Map.get(profile, :avatar_url),
          source: :oauth,
          oauth_provider: provider
        })
    end
  end
end

defmodule Auth.OAuthClient do
  @spec exchange_code(atom(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def exchange_code(provider, code, redirect_uri) do
    config = provider_config(provider)

    case HTTPoison.post(
           config.token_url,
           Jason.encode!(%{
             code: code,
             client_id: config.client_id,
             client_secret: config.client_secret,
             redirect_uri: redirect_uri,
             grant_type: "authorization_code"
           }),
           [{"Content-Type", "application/json"}]
         ) do
      {:ok, %{status_code: 200, body: body}} -> {:ok, Jason.decode!(body, keys: :atoms)}
      _ -> {:error, :provider_error}
    end
  end

  @spec fetch_profile(atom(), String.t()) :: {:ok, map()} | {:error, atom()}
  def fetch_profile(provider, access_token) do
    config = provider_config(provider)

    case HTTPoison.get(config.profile_url, [{"Authorization", "Bearer #{access_token}"}]) do
      {:ok, %{status_code: 200, body: body}} -> {:ok, Jason.decode!(body, keys: :atoms)}
      _ -> {:error, :provider_error}
    end
  end

  defp provider_config(:google),
    do: %{
      token_url: "https://oauth2.googleapis.com/token",
      profile_url: "https://www.googleapis.com/oauth2/v2/userinfo",
      client_id: Application.fetch_env!(:my_app, :google_client_id),
      client_secret: Application.fetch_env!(:my_app, :google_client_secret)
    }

  defp provider_config(:github),
    do: %{
      token_url: "https://github.com/login/oauth/access_token",
      profile_url: "https://api.github.com/user",
      client_id: Application.fetch_env!(:my_app, :github_client_id),
      client_secret: Application.fetch_env!(:my_app, :github_client_secret)
    }

  defp provider_config(:microsoft),
    do: %{
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      profile_url: "https://graph.microsoft.com/v1.0/me",
      client_id: Application.fetch_env!(:my_app, :microsoft_client_id),
      client_secret: Application.fetch_env!(:my_app, :microsoft_client_secret)
    }
end
```
