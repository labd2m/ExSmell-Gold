```elixir
defmodule Auth.OAuthCallbackHandler do
  @moduledoc """
  Handles OAuth 2.0 callback requests from third-party identity providers.
  Exchanges the authorisation code for an access token, fetches the user
  profile, and either creates or links the account in the local database.
  """

  require Logger

  alias Auth.{OAuthClient, UserRepo, SessionManager, TokenStore}

  @state_ttl_seconds 600

  @spec handle(map()) :: {:ok, String.t()} | {:error, term()}
  def handle(%{"code" => code, "state" => state, "provider" => provider_name} = params) do
    Logger.info("OAuth callback received", provider: provider_name)

    with {:ok, provider} <- infer_provider(provider_name),
         {:ok, csrf_data} <- validate_state(state),
         {:ok, token_response} <- OAuthClient.exchange_code(provider, code),
         {:ok, profile} <- OAuthClient.fetch_profile(provider, token_response["access_token"]),
         {:ok, user} <- find_or_create_user(provider, profile),
         {:ok, session_token} <- SessionManager.create(user, %{provider: provider}) do
      TokenStore.store(user.id, provider, token_response)
      Logger.info("OAuth login successful", user_id: user.id, provider: provider)
      {:ok, session_token}
    else
      {:error, :invalid_state} ->
        Logger.warning("OAuth CSRF state validation failed", state: state)
        {:error, :invalid_state}

      {:error, :unsupported_provider} ->
        Logger.warning("Unsupported OAuth provider", provider: provider_name)
        {:error, :unsupported_provider}

      {:error, reason} = err ->
        Logger.error("OAuth callback failed",
          provider: provider_name,
          reason: inspect(reason)
        )
        err
    end
  end

  def handle(params) do
    Logger.warning("Malformed OAuth callback params", params: inspect(params))
    {:error, :malformed_callback}
  end

  defp infer_provider(provider_name) when is_binary(provider_name) do
    {:ok, String.to_atom(provider_name)}
  end

  defp infer_provider(_), do: {:error, :unsupported_provider}

  defp validate_state(state) when is_binary(state) do
    case TokenStore.pop_state(state) do
      {:ok, csrf_data} ->
        if not expired?(csrf_data),
          do: {:ok, csrf_data},
          else: {:error, :invalid_state}

      :error ->
        {:error, :invalid_state}
    end
  end

  defp validate_state(_), do: {:error, :invalid_state}

  defp expired?(%{issued_at: issued_at}) do
    now = System.system_time(:second)
    now - issued_at > @state_ttl_seconds
  end

  defp find_or_create_user(provider, %{"sub" => sub} = profile) do
    case UserRepo.find_by_oauth(provider, sub) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        UserRepo.create_from_oauth(provider, sub, %{
          email: profile["email"],
          name: profile["name"],
          avatar_url: profile["picture"]
        })
    end
  end

  defp find_or_create_user(_, _), do: {:error, :missing_subject_claim}
end
```
