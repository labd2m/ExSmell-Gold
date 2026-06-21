```elixir
defmodule MyApp.Auth.Guardian do
  @moduledoc """
  Implements `Guardian` behaviour for JWT-based API authentication.
  Claims are kept minimal: only the subject (user ID) and a `typ`
  discriminator are stored inside the token so that the payload stays
  compact and does not leak sensitive user data to clients.

  Token types:
  * `"access"`  — short-lived (15 minutes), used in `Authorization` headers.
  * `"refresh"` — long-lived (30 days), used only to obtain new access tokens.
  """

  use Guardian, otp_app: :my_app

  alias MyApp.Accounts
  alias MyApp.Accounts.User

  @access_ttl {15, :minute}
  @refresh_ttl {30, :day}

  @doc "Issues a matched pair of access and refresh tokens for `user`."
  @spec issue_tokens(User.t()) ::
          {:ok, %{access: String.t(), refresh: String.t()}} | {:error, term()}
  def issue_tokens(%User{} = user) do
    with {:ok, access, _claims} <- encode_and_sign(user, %{"typ" => "access"}, ttl: @access_ttl),
         {:ok, refresh, _claims} <-
           encode_and_sign(user, %{"typ" => "refresh"}, ttl: @refresh_ttl) do
      {:ok, %{access: access, refresh: refresh}}
    end
  end

  @doc """
  Exchanges a valid refresh token for a new access token.
  Returns `{:error, :wrong_token_type}` when given an access token.
  """
  @spec refresh_access(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh_access(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token),
         :ok <- assert_token_type(claims, "refresh"),
         {:ok, user} <- resource_from_claims(claims),
         {:ok, access, _claims} <-
           encode_and_sign(user, %{"typ" => "access"}, ttl: @access_ttl) do
      {:ok, access}
    end
  end

  @doc """
  Verifies an access token and returns the owning user.
  Returns `{:error, :wrong_token_type}` when given a refresh token.
  """
  @spec verify_access(String.t()) :: {:ok, User.t()} | {:error, term()}
  def verify_access(token) when is_binary(token) do
    with {:ok, claims} <- decode_and_verify(token),
         :ok <- assert_token_type(claims, "access"),
         {:ok, user} <- resource_from_claims(claims) do
      {:ok, user}
    end
  end

  @impl Guardian
  def subject_for_token(%User{id: id}, _claims), do: {:ok, to_string(id)}
  def subject_for_token(_, _), do: {:error, :unsupported_resource}

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.fetch_user(id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :resource_not_found}
    end
  end

  def resource_from_claims(_), do: {:error, :missing_subject}

  @spec assert_token_type(map(), String.t()) :: :ok | {:error, :wrong_token_type}
  defp assert_token_type(%{"typ" => typ}, expected) when typ == expected, do: :ok
  defp assert_token_type(_, _), do: {:error, :wrong_token_type}
end
```
