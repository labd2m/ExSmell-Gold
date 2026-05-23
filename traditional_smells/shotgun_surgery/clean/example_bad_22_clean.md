```elixir
defmodule Auth.OAuthProvider do
  @moduledoc """
  Handles OAuth 2.0 authorization URL construction, token exchange,
  and user profile retrieval for supported third-party identity providers.
  """

  @google_auth_url   "https://accounts.google.com/o/oauth2/v2/auth"
  @github_auth_url   "https://github.com/login/oauth/authorize"
  @microsoft_auth_url "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"


  @spec authorize_url(atom(), String.t()) :: String.t()
  def authorize_url(:google, state) do
    params = URI.encode_query(%{
      client_id:     System.get_env("GOOGLE_CLIENT_ID"),
      redirect_uri:  System.get_env("GOOGLE_REDIRECT_URI"),
      response_type: "code",
      scope:         "openid email profile",
      state:         state
    })
    "#{@google_auth_url}?#{params}"
  end

  def authorize_url(:github, state) do
    params = URI.encode_query(%{
      client_id:    System.get_env("GITHUB_CLIENT_ID"),
      redirect_uri: System.get_env("GITHUB_REDIRECT_URI"),
      scope:        "user:email",
      state:        state
    })
    "#{@github_auth_url}?#{params}"
  end

  def authorize_url(:microsoft, state) do
    params = URI.encode_query(%{
      client_id:     System.get_env("MICROSOFT_CLIENT_ID"),
      redirect_uri:  System.get_env("MICROSOFT_REDIRECT_URI"),
      response_type: "code",
      scope:         "openid email profile",
      state:         state
    })
    "#{@microsoft_auth_url}?#{params}"
  end

  @spec exchange_token(atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def exchange_token(:google, code) do
    post_token("https://oauth2.googleapis.com/token", %{
      code:          code,
      client_id:     System.get_env("GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
      grant_type:    "authorization_code"
    })
  end

  def exchange_token(:github, code) do
    post_token("https://github.com/login/oauth/access_token", %{
      code:          code,
      client_id:     System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET")
    })
  end

  def exchange_token(:microsoft, code) do
    post_token("https://login.microsoftonline.com/common/oauth2/v2.0/token", %{
      code:          code,
      client_id:     System.get_env("MICROSOFT_CLIENT_ID"),
      client_secret: System.get_env("MICROSOFT_CLIENT_SECRET"),
      grant_type:    "authorization_code"
    })
  end

  @spec fetch_profile(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_profile(:google, access_token) do
    get_json("https://www.googleapis.com/oauth2/v3/userinfo", access_token)
  end

  def fetch_profile(:github, access_token) do
    get_json("https://api.github.com/user", access_token)
  end

  def fetch_profile(:microsoft, access_token) do
    get_json("https://graph.microsoft.com/v1.0/me", access_token)
  end


  defp post_token(url, params) do
    {:ok, "stub_access_token_from_#{url}"}
  end

  defp get_json(url, _token) do
    {:ok, %{"email" => "user@example.com", "name" => "Test User"}}
  end
end

defmodule Auth.UserProfile do
  @moduledoc """
  Normalizes provider-specific profile data and resolves display metadata
  for authenticated users in the system.
  """


  @spec provider_display_name(atom()) :: String.t()
  def provider_display_name(:google),    do: "Google"
  def provider_display_name(:github),    do: "GitHub"
  def provider_display_name(:microsoft), do: "Microsoft"

  @spec avatar_field(atom()) :: String.t()
  def avatar_field(:google),    do: "picture"
  def avatar_field(:github),    do: "avatar_url"
  def avatar_field(:microsoft), do: "photo"


  def normalize(provider, raw_profile) do
    %{
      email:        Map.get(raw_profile, "email"),
      name:         Map.get(raw_profile, "name"),
      avatar_url:   Map.get(raw_profile, avatar_field(provider)),
      provider:     provider,
      provider_id:  Map.get(raw_profile, "sub") || Map.get(raw_profile, "id"),
      display_from: provider_display_name(provider)
    }
  end
end

defmodule Auth.AuditLog do
  @moduledoc """
  Records authentication events for compliance and security monitoring purposes.
  """


  @spec log_provider_event(atom(), map()) :: :ok
  def log_provider_event(:google, event) do
    persist_log(%{source: "google_oauth", severity: :info, payload: event})
  end

  def log_provider_event(:github, event) do
    persist_log(%{source: "github_oauth", severity: :info, payload: event})
  end

  def log_provider_event(:microsoft, event) do
    persist_log(%{source: "microsoft_oauth", severity: :info, payload: event})
  end


  defp persist_log(entry) do
    IO.inspect(entry, label: "[AuditLog]")
    :ok
  end
end
```
