```elixir
defmodule MyApp.Auth.OAuthHandler do
  @moduledoc """
  Handles the OAuth 2.0 authorization code flow for each supported identity provider.
  Exchanges authorization codes for access tokens and fetches raw user profiles.
  """

  alias MyApp.Auth.{TokenValidator, UserMapper}
  alias MyApp.Integrations.{GoogleOAuth, GitHubOAuth, FacebookOAuth}

  require Logger

  def exchange_code(:google, code, redirect_uri) do
    with {:ok, tokens} <- GoogleOAuth.exchange_code(code, redirect_uri),
         {:ok, _claims} <- TokenValidator.verify(:google, tokens.id_token),
         {:ok, profile} <- GoogleOAuth.get_userinfo(tokens.access_token),
         {:ok, user_attrs} <- UserMapper.map_profile(:google, profile) do
      Logger.info("Google OAuth success", sub: profile["sub"])
      {:ok, user_attrs, tokens}
    else
      {:error, reason} ->
        Logger.warning("Google OAuth failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  def exchange_code(:github, code, redirect_uri) do
    with {:ok, tokens} <- GitHubOAuth.exchange_code(code, redirect_uri),
         {:ok, profile} <- GitHubOAuth.get_user(tokens.access_token),
         {:ok, _} <- TokenValidator.verify(:github, tokens.access_token),
         {:ok, user_attrs} <- UserMapper.map_profile(:github, profile) do
      Logger.info("GitHub OAuth success", login: profile["login"])
      {:ok, user_attrs, tokens}
    else
      {:error, reason} ->
        Logger.warning("GitHub OAuth failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  def exchange_code(:facebook, code, redirect_uri) do
    with {:ok, tokens} <- FacebookOAuth.exchange_code(code, redirect_uri),
         {:ok, _debug} <- TokenValidator.verify(:facebook, tokens.access_token),
         {:ok, profile} <- FacebookOAuth.get_me(tokens.access_token),
         {:ok, user_attrs} <- UserMapper.map_profile(:facebook, profile) do
      Logger.info("Facebook OAuth success", id: profile["id"])
      {:ok, user_attrs, tokens}
    else
      {:error, reason} ->
        Logger.warning("Facebook OAuth failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  def exchange_code(unknown_provider, _code, _redirect_uri) do
    {:error, {:unsupported_provider, unknown_provider}}
  end
end

defmodule MyApp.Auth.TokenValidator do
  @moduledoc """
  Verifies identity tokens and access tokens for each supported OAuth provider.
  Validation strategies differ per provider: JWT verification for Google,
  token introspection for GitHub, and debug_token API calls for Facebook.
  """

  alias MyApp.Integrations.{GoogleJwks, GitHubOAuth, FacebookOAuth}

  @google_issuer "https://accounts.google.com"
  @google_client_id Application.compile_env!(:my_app, :google_client_id)

  def verify(:google, id_token) do
    with {:ok, jwks} <- GoogleJwks.fetch(),
         {:ok, claims} <- Joken.verify(id_token, jwks),
         :ok <- validate_google_claims(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, {:google_token_invalid, reason}}
    end
  end

  def verify(:github, access_token) do
    case GitHubOAuth.introspect_token(access_token) do
      {:ok, %{"login" => _login} = info} -> {:ok, info}
      {:ok, _} -> {:error, :github_token_inactive}
      {:error, reason} -> {:error, {:github_token_error, reason}}
    end
  end

  def verify(:facebook, access_token) do
    app_token = "#{Application.fetch_env!(:my_app, :facebook_app_id)}|#{Application.fetch_env!(:my_app, :facebook_secret)}"

    case FacebookOAuth.debug_token(access_token, app_token) do
      {:ok, %{"data" => %{"is_valid" => true} = data}} -> {:ok, data}
      {:ok, %{"data" => %{"is_valid" => false}}} -> {:error, :facebook_token_invalid}
      {:error, reason} -> {:error, {:facebook_debug_error, reason}}
    end
  end

  def verify(unknown_provider, _token) do
    {:error, {:unsupported_provider, unknown_provider}}
  end

  defp validate_google_claims(%{"iss" => @google_issuer, "aud" => @google_client_id}), do: :ok
  defp validate_google_claims(_), do: {:error, :google_claims_mismatch}
end

defmodule MyApp.Auth.UserMapper do
  @moduledoc """
  Normalizes raw provider profile payloads into a unified user attribute map
  suitable for upsert into the application's accounts table.
  """

  def map_profile(:google, profile) do
    attrs = %{
      provider: :google,
      provider_id: profile["sub"],
      email: profile["email"],
      email_verified: profile["email_verified"] == true,
      name: profile["name"],
      given_name: profile["given_name"],
      family_name: profile["family_name"],
      avatar_url: profile["picture"],
      locale: profile["locale"]
    }

    {:ok, attrs}
  end

  def map_profile(:github, profile) do
    attrs = %{
      provider: :github,
      provider_id: to_string(profile["id"]),
      email: profile["email"],
      email_verified: profile["email"] != nil,
      name: profile["name"] || profile["login"],
      given_name: nil,
      family_name: nil,
      avatar_url: profile["avatar_url"],
      locale: nil
    }

    {:ok, attrs}
  end

  def map_profile(:facebook, profile) do
    [given_name | rest] = String.split(profile["name"] || "", " ", parts: 2)

    attrs = %{
      provider: :facebook,
      provider_id: profile["id"],
      email: profile["email"],
      email_verified: Map.get(profile, "verified", false),
      name: profile["name"],
      given_name: given_name,
      family_name: List.first(rest),
      avatar_url: get_in(profile, ["picture", "data", "url"]),
      locale: profile["locale"]
    }

    {:ok, attrs}
  end

  def map_profile(unknown_provider, _profile) do
    {:error, {:unsupported_provider, unknown_provider}}
  end
end
```
