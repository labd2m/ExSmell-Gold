```elixir
defmodule Accounts.TwoFactor do
  @moduledoc """
  Context for TOTP-based two-factor authentication, compliant with RFC 6238.

  Secrets are base32-encoded 160-bit random values. Verification accepts
  a one-step window around the current time to tolerate minor clock drift
  between client and server. Secrets are never logged or returned after
  initial setup confirmation.
  """

  alias Accounts.{Repo, User}

  @type user_id :: pos_integer()
  @type totp_secret :: String.t()
  @type totp_code :: String.t()
  @type setup_result :: {:ok, %{secret: totp_secret(), provisioning_uri: String.t()}}

  @digits 6
  @period 30
  @drift_window 1

  @doc """
  Generates a fresh TOTP secret and provisioning URI for QR code display.
  The secret is not persisted; call `confirm_and_enable/3` after the user
  successfully scans and verifies it.
  """
  @spec begin_setup(user_id(), String.t()) :: setup_result()
  def begin_setup(user_id, issuer) when is_integer(user_id) and is_binary(issuer) do
    secret = generate_secret()
    uri = provisioning_uri(secret, "user:#{user_id}", issuer)
    {:ok, %{secret: secret, provisioning_uri: uri}}
  end

  @doc """
  Verifies `code` against `secret` and, if valid, enables 2FA on the user record.
  Returns `{:error, :invalid_code}` when the code does not match any valid window.
  """
  @spec confirm_and_enable(user_id(), totp_secret(), totp_code()) ::
          :ok | {:error, :invalid_code | Ecto.Changeset.t()}
  def confirm_and_enable(user_id, secret, code) when is_binary(secret) and is_binary(code) do
    if valid?(secret, code) do
      user_id
      |> Repo.get!(User)
      |> User.enable_2fa_changeset(%{totp_secret: secret, two_factor_enabled: true})
      |> Repo.update()
      |> normalize_update()
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Verifies a login-time TOTP code for a user with 2FA already enabled.
  """
  @spec verify(user_id(), totp_code()) ::
          :ok | {:error, :invalid_code | :not_enabled}
  def verify(user_id, code) when is_binary(code) do
    case Repo.get(User, user_id) do
      %User{two_factor_enabled: true, totp_secret: secret} when is_binary(secret) ->
        if valid?(secret, code), do: :ok, else: {:error, :invalid_code}

      _ ->
        {:error, :not_enabled}
    end
  end

  @doc """
  Disables 2FA for a user after verifying their current code.
  """
  @spec disable(user_id(), totp_code()) :: :ok | {:error, :invalid_code | :not_enabled | Ecto.Changeset.t()}
  def disable(user_id, code) do
    with :ok <- verify(user_id, code) do
      user_id
      |> Repo.get!(User)
      |> User.enable_2fa_changeset(%{totp_secret: nil, two_factor_enabled: false})
      |> Repo.update()
      |> normalize_update()
    end
  end

  defp valid?(secret, code) do
    current = time_step()

    Enum.any?(-@drift_window..@drift_window, fn offset ->
      expected = generate_totp(secret, current + offset)
      Plug.Crypto.secure_compare(expected, String.trim(code))
    end)
  end

  defp generate_totp(secret, step) do
    key = Base.decode32!(secret, padding: false)
    message = <<step::unsigned-big-integer-64>>
    mac = :crypto.mac(:hmac, :sha, key, message)
    <<_::4, offset::4, _::binary>> = mac
    <<truncated::unsigned-big-integer-32, _::binary>> = binary_part(mac, offset, 4)
    code = rem(truncated &&& 0x7FFFFFFF, trunc(:math.pow(10, @digits)))
    code |> Integer.to_string() |> String.pad_leading(@digits, "0")
  end

  defp time_step, do: System.os_time(:second) |> div(@period)

  defp generate_secret do
    :crypto.strong_rand_bytes(20) |> Base.encode32(padding: false)
  end

  defp provisioning_uri(secret, account, issuer) do
    account_enc = URI.encode(account)
    issuer_enc = URI.encode(issuer)
    "otpauth://totp/#{issuer_enc}:#{account_enc}?secret=#{secret}&issuer=#{issuer_enc}&digits=#{@digits}&period=#{@period}"
  end

  defp normalize_update({:ok, _}), do: :ok
  defp normalize_update({:error, changeset}), do: {:error, changeset}
end
```
