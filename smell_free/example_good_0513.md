```elixir
defmodule MyApp.Accounts.EmailVerifier do
  @moduledoc """
  Handles the email verification lifecycle: generating signed verification
  tokens, confirming addresses, and supporting email-change flows where
  the old address must be notified and the new address must confirm.

  All token operations use HMAC-signed payloads rather than database-stored
  secrets, so no cleanup job is needed for expired tokens — they simply
  stop verifying once past their expiry.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Mailer

  @hmac_key Application.compile_env!(:my_app, :email_verification_hmac_key)
  @token_validity_hours 48

  @type raw_token :: String.t()

  @doc """
  Generates a signed email verification token for `user` and delivers
  it to `user.email`. Returns `{:ok, raw_token}`.
  """
  @spec send_verification(User.t()) :: {:ok, raw_token()} | {:error, term()}
  def send_verification(%User{} = user) do
    token = build_token(user.id, user.email)

    case Mailer.deliver_email_verification(user, token) do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies `token` and marks the user's email as confirmed.
  Returns `{:error, :invalid_token}` for expired or tampered tokens.
  """
  @spec confirm(raw_token()) :: {:ok, User.t()} | {:error, :invalid_token}
  def confirm(token) when is_binary(token) do
    with {:ok, user_id, email} <- decode_token(token),
         {:ok, user} <- fetch_user_for_confirmation(user_id, email) do
      user
      |> User.confirm_email_changeset()
      |> Repo.update()
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc """
  Initiates an email-change flow: sends a notification to the current
  address and a confirmation link to the new address.
  """
  @spec initiate_change(User.t(), String.t()) ::
          {:ok, raw_token()} | {:error, :same_email} | {:error, term()}
  def initiate_change(%User{} = user, new_email)
      when is_binary(new_email) do
    cond do
      String.downcase(new_email) == String.downcase(user.email) ->
        {:error, :same_email}

      true ->
        token = build_token(user.id, new_email)
        notify_old_address(user)
        deliver_change_confirmation(user, new_email, token)
        {:ok, token}
    end
  end

  @doc """
  Confirms an email change by verifying `token` and updating the user's
  email address.
  """
  @spec confirm_change(raw_token()) :: {:ok, User.t()} | {:error, :invalid_token}
  def confirm_change(token) when is_binary(token) do
    with {:ok, user_id, new_email} <- decode_token(token),
         user when not is_nil(user) <- Repo.get(User, user_id) do
      user
      |> User.email_change_changeset(%{email: new_email})
      |> Repo.update()
    else
      _ -> {:error, :invalid_token}
    end
  end

  @spec build_token(String.t(), String.t()) :: raw_token()
  defp build_token(user_id, email) do
    ts = System.os_time(:second)
    payload = "#{user_id}|#{email}|#{ts}"
    sig = :crypto.mac(:hmac, :sha256, @hmac_key, payload) |> Base.url_encode64(padding: false)
    "#{Base.url_encode64(payload, padding: false)}.#{sig}"
  end

  @spec decode_token(raw_token()) :: {:ok, String.t(), String.t()} | :error
  defp decode_token(token) do
    with [encoded_payload, sig] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
         [user_id, email, ts_str] <- String.split(payload, "|", parts: 3),
         {ts, ""} <- Integer.parse(ts_str),
         true <- System.os_time(:second) - ts <= @token_validity_hours * 3_600,
         expected <- :crypto.mac(:hmac, :sha256, @hmac_key, payload) |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(sig, expected) do
      {:ok, user_id, email}
    else
      _ -> :error
    end
  end

  @spec fetch_user_for_confirmation(String.t(), String.t()) ::
          {:ok, User.t()} | :error
  defp fetch_user_for_confirmation(user_id, email) do
    case Repo.get_by(User, id: user_id, email: email, confirmed: false) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  @spec notify_old_address(User.t()) :: :ok
  defp notify_old_address(user) do
    Mailer.deliver_email_change_notice(user)
    :ok
  end

  @spec deliver_change_confirmation(User.t(), String.t(), raw_token()) :: :ok
  defp deliver_change_confirmation(user, new_email, token) do
    Mailer.deliver_email_change_confirmation(user, new_email, token)
    :ok
  end
end
```
