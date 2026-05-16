```elixir
defmodule MyApp.UserAuth do
  @moduledoc """
  Handles user authentication and token issuance for the web application.
  Supports multiple credential types and integrates with the session store.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Auth.TokenStore
  alias MyApp.Auth.PasswordHasher

  @token_ttl_seconds 86_400
  @refresh_ttl_seconds 604_800

  def authenticate(credentials, opts \\ []) when is_list(opts) do
    format = Keyword.get(opts, :format, :tuple)
    include_refresh = Keyword.get(opts, :include_refresh, false)

    with {:ok, user} <- lookup_user(credentials[:email]),
         :ok <- verify_password(user, credentials[:password]),
         {:ok, token} <- TokenStore.issue(user.id, ttl: @token_ttl_seconds) do
      case format do
        :map ->
          result = %{
            access_token: token,
            user_id: user.id,
            email: user.email,
            role: user.role,
            expires_in: @token_ttl_seconds
          }

          if include_refresh do
            {:ok, refresh} = TokenStore.issue(user.id, ttl: @refresh_ttl_seconds, type: :refresh)
            Map.put(result, :refresh_token, refresh)
          else
            result
          end

        :raw ->
          token

        :tuple ->
          if include_refresh do
            {:ok, refresh} = TokenStore.issue(user.id, ttl: @refresh_ttl_seconds, type: :refresh)
            {:ok, token, refresh, user}
          else
            {:ok, token, user}
          end

        _ ->
          {:error, :unknown_format}
      end
    else
      {:error, :not_found} -> {:error, :invalid_credentials}
      {:error, :wrong_password} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_token(token) do
    TokenStore.revoke(token)
  end

  def refresh_token(refresh_token, opts \\ []) do
    with {:ok, claims} <- TokenStore.verify(refresh_token, type: :refresh),
         {:ok, user} <- Repo.fetch(User, claims.user_id),
         {:ok, new_token} <- TokenStore.issue(user.id, ttl: @token_ttl_seconds) do
      {:ok, new_token, user}
    end
  end

  def active_sessions(user_id) do
    TokenStore.list_active(user_id)
  end

  defp lookup_user(nil), do: {:error, :not_found}

  defp lookup_user(email) do
    case Repo.get_by(User, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp verify_password(user, password) do
    if PasswordHasher.valid?(password, user.password_hash) do
      :ok
    else
      {:error, :wrong_password}
    end
  end
end
```
