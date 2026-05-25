## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** Function `generate_token/2` in `Auth.TokenManager`
- **Affected function(s):** `generate_token/2`
- **Explanation:** The `token_size` parameter was added with a default value of `64` speculatively, anticipating future call sites that might request tokens of varying byte lengths — for example, short 16-byte tokens for SMS OTP flows or 128-byte tokens for high-security long-lived API keys. In practice, every call site in the codebase invokes `generate_token/1` without supplying a second argument, so the parameter is never actually varied and always uses the default.

---

```elixir
defmodule Auth.TokenManager do
  @moduledoc """
  Manages the full lifecycle of authentication tokens, including generation,
  validation, refresh, and revocation for user sessions.
  """

  alias Auth.{User, TokenStore}

  @access_token_ttl_seconds  3_600
  @refresh_token_ttl_seconds 86_400 * 30
  @max_active_sessions       5

  def authenticate(%{"email" => email, "password" => password}) do
    with {:ok, user}    <- User.fetch_by_email(email),
         :ok            <- verify_password(user, password),
         :ok            <- check_account_status(user),
         {:ok, session} <- create_session(user) do
      {:ok, session}
    end
  end

  def create_session(%User{} = user) do
    :ok = enforce_session_cap(user)

    with {:ok, access_token}  <- generate_token(user.id),
         {:ok, refresh_token} <- generate_refresh_token(user.id) do
      now = DateTime.utc_now()

      session = %{
        user_id:       user.id,
        access_token:  access_token,
        refresh_token: refresh_token,
        issued_at:     now,
        expires_at:    DateTime.add(now, @access_token_ttl_seconds)
      }

      case TokenStore.insert(session) do
        :ok             -> {:ok, session}
        {:error, _} = e -> e
      end
    end
  end

  def refresh(%{"refresh_token" => raw_token}) do
    with {:ok, claims}  <- TokenStore.lookup_refresh(raw_token),
         false          <- claims_expired?(claims),
         {:ok, user}    <- User.fetch(claims.user_id),
         :ok            <- TokenStore.revoke_refresh(raw_token),
         {:ok, session} <- create_session(user) do
      {:ok, session}
    else
      true  -> {:error, :refresh_token_expired}
      error -> error
    end
  end

  def validate(%{"token" => raw_token}) do
    case TokenStore.lookup(raw_token) do
      {:ok, claims} ->
        if claims_expired?(claims) do
          TokenStore.revoke(raw_token)
          {:error, :token_expired}
        else
          {:ok, claims}
        end

      {:error, :not_found} ->
        {:error, :invalid_token}
    end
  end

  def revoke(%{"token" => raw_token}) do
    case TokenStore.revoke(raw_token) do
      :ok                  -> :ok
      {:error, :not_found} -> {:error, :invalid_token}
      error                -> error
    end
  end

  def revoke_all_sessions(%User{id: user_id}) do
    TokenStore.revoke_all(user_id)
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because the `token_size` parameter was added
  # speculatively, expecting future call sites to request tokens of varying byte
  # lengths (e.g., a 16-byte numeric OTP, a 32-byte standard session token, or a
  # 128-byte long-lived API key). Every existing call site uses `generate_token/1`,
  # so the second parameter is never supplied and the default value of 64 is always
  # in effect. The generalisation never materialised into actual varied use.
  def generate_token(user_id, token_size \\ 64) do
    raw =
      token_size
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    {:ok, "#{user_id}.#{raw}"}
  end
  # VALIDATION: SMELL END

  defp generate_refresh_token(user_id) do
    raw =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    {:ok, "r.#{user_id}.#{raw}"}
  end

  defp verify_password(%User{password_hash: hash}, password) do
    if Bcrypt.verify_pass(password, hash),
      do: :ok,
      else: {:error, :invalid_credentials}
  end

  defp check_account_status(%User{status: :active}),    do: :ok
  defp check_account_status(%User{status: :suspended}), do: {:error, :account_suspended}
  defp check_account_status(%User{status: :deleted}),   do: {:error, :account_not_found}
  defp check_account_status(_),                         do: {:error, :unknown_account_status}

  defp enforce_session_cap(%User{id: user_id}) do
    if TokenStore.count_active(user_id) >= @max_active_sessions do
      TokenStore.revoke_oldest(user_id)
    end

    :ok
  end

  defp claims_expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
```
