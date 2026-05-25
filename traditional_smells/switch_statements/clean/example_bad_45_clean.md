```elixir
defmodule OAuthHandler do
  @moduledoc """
  Manages OAuth 2.0 authentication flows for multiple identity providers.
  Handles token exchange, user profile normalisation, and provider-specific
  display metadata for a single-sign-on enabled application.
  """

  alias OAuthHandler.{
    OAuthToken,
    UserProfile,
    ProviderClient,
    SessionStore,
    AuditLog
  }

  @type provider :: :google | :github | :microsoft | :slack | :apple

  @spec initiate_flow(provider(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_flow(provider, redirect_uri) do
    case ProviderClient.build_authorisation_url(provider, redirect_uri) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        {:error, "could not initiate #{provider_display_name(provider)} login: #{reason}"}
    end
  end

  @spec handle_callback(provider(), String.t(), String.t()) ::
          {:ok, UserProfile.t()} | {:error, String.t()}
  def handle_callback(provider, code, redirect_uri) do
    with {:ok, token} <- ProviderClient.exchange_code(provider, code, redirect_uri),
         {:ok, raw_profile} <- ProviderClient.fetch_profile(provider, token),
         {:ok, profile} <- normalise_profile(provider, raw_profile, token) do
      AuditLog.record(:oauth_login, profile.email, %{provider: provider})
      {:ok, profile}
    end
  end

  @spec provider_login_buttons() :: [map()]
  def provider_login_buttons do
    [:google, :github, :microsoft, :slack, :apple]
    |> Enum.map(fn provider ->
      %{
        provider: provider,
        label: "Continue with #{provider_display_name(provider)}",
        icon: provider_icon_path(provider)
      }
    end)
  end

  @spec link_additional_provider(String.t(), provider(), String.t()) ::
          :ok | {:error, String.t()}
  def link_additional_provider(user_id, provider, code) do
    with {:ok, token} <- ProviderClient.exchange_code(provider, code, nil),
         {:ok, _profile} <- ProviderClient.fetch_profile(provider, token),
         :ok <- SessionStore.record_linked_provider(user_id, provider) do
      AuditLog.record(:provider_linked, user_id, %{provider: provider})
      :ok
    end
  end

  @spec provider_display_name(provider()) :: String.t()
  def provider_display_name(provider) do
    case provider do
      :google    -> "Google"
      :github    -> "GitHub"
      :microsoft -> "Microsoft"
      :slack     -> "Slack"
      :apple     -> "Apple"
    end
  end

  @spec provider_icon_path(provider()) :: String.t()
  def provider_icon_path(provider) do
    case provider do
      :google    -> "/images/providers/google.svg"
      :github    -> "/images/providers/github.svg"
      :microsoft -> "/images/providers/microsoft.svg"
      :slack     -> "/images/providers/slack.svg"
      :apple     -> "/images/providers/apple.svg"
    end
  end

  @spec normalise_profile(provider(), map(), OAuthToken.t()) ::
          {:ok, UserProfile.t()} | {:error, String.t()}
  defp normalise_profile(:google, raw, token) do
    {:ok,
     %UserProfile{
       provider: :google,
       external_id: raw["sub"],
       email: raw["email"],
       name: raw["name"],
       avatar_url: raw["picture"],
       token: token
     }}
  end

  defp normalise_profile(:github, raw, token) do
    {:ok,
     %UserProfile{
       provider: :github,
       external_id: Integer.to_string(raw["id"]),
       email: raw["email"],
       name: raw["name"] || raw["login"],
       avatar_url: raw["avatar_url"],
       token: token
     }}
  end

  defp normalise_profile(:microsoft, raw, token) do
    {:ok,
     %UserProfile{
       provider: :microsoft,
       external_id: raw["id"],
       email: raw["mail"] || raw["userPrincipalName"],
       name: raw["displayName"],
       avatar_url: nil,
       token: token
     }}
  end

  defp normalise_profile(provider, _raw, _token) do
    {:error, "profile normalisation not implemented for #{provider}"}
  end
end
```
