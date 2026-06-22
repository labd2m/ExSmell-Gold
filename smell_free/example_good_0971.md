```elixir
defmodule MyApp.Accounts.PasswordResetFlow do
  @moduledoc """
  Manages the full password reset lifecycle: requesting a reset token,
  validating it, and applying the new password. Tokens are time-limited
  HMAC signatures so no token table or background cleanup job is needed.
  Rate limiting prevents abuse by throttling reset requests per email
  address using the in-process rate limiter.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.{User, PasswordPolicy}
  alias MyApp.Mailer
  alias MyApp.RateLimiter

  @hmac_key Application.compile_env!(:my_app, :password_reset_hmac_key)
  @token_ttl_minutes 60
  @rate_limit_key_prefix "pwd_reset:"

  @type raw_token :: String.t()

  @doc """
  Requests a password reset for `email`. Delivers a reset link when the
  email matches an active account. Always returns `:ok` to prevent user
  enumeration, even when no account is found.
  """
  @spec request(String.t()) :: :ok
  def request(email) when is_binary(email) do
    rate_key = @rate_limit_key_prefix <> String.downcase(email)

    case RateLimiter.check(rate_key) do
      {:ok, _remaining} ->
        do_request(String.downcase(email))

      {:error, :rate_limited} ->
        :ok
    end
  end

  @doc """
  Validates `raw_token` and applies `new_password` if valid.
  Returns `{:error, :invalid_token}` for expired or tampered tokens,
  or `{:error, violations}` when the password does not meet policy.
  """
  @spec reset(raw_token(), String.t()) ::
          :ok
          | {:error, :invalid_token}
          | {:error, :user_not_found}
          | {:error, [atom()]}
          | {:error, Ecto.Changeset.t()}
  def reset(raw_token, new_password) when is_binary(raw_token) and is_binary(new_password) do
    with {:ok, user_id} <- decode_token(raw_token),
         {:ok, user} <- fetch_user(user_id),
         {:ok, hash} <- PasswordPolicy.validate_and_hash(new_password) do
      user
      |> User.password_changeset(%{password_hash: hash})
      |> Repo.update()

      :ok
    end
  end

  @spec do_request(String.t()) :: :ok
  defp do_request(email) do
    case Repo.get_by(User, email: email, active: true) do
      nil ->
        :ok

      user ->
        token = build_token(user.id)
        Mailer.deliver_password_reset(user, token)
        :ok
    end
  end

  @spec build_token(String.t()) :: raw_token()
  defp build_token(user_id) do
    ts = System.os_time(:second)
    payload = "#{user_id}|#{ts}"
    sig = :crypto.mac(:hmac, :sha256, @hmac_key, payload) |> Base.url_encode64(padding: false)
    "#{Base.url_encode64(payload, padding: false)}.#{sig}"
  end

  @spec decode_token(raw_token()) :: {:ok, String.t()} | {:error, :invalid_token}
  defp decode_token(token) do
    with [encoded_payload, sig] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
         [user_id, ts_str] <- String.split(payload, "|", parts: 2),
         {ts, ""} <- Integer.parse(ts_str),
         true <- System.os_time(:second) - ts <= @token_ttl_minutes * 60,
         expected <- :crypto.mac(:hmac, :sha256, @hmac_key, payload) |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(sig, expected) do
      {:ok, user_id}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @spec fetch_user(String.t()) :: {:ok, User.t()} | {:error, :user_not_found}
  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end
end
```
