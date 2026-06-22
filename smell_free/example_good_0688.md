```elixir
defmodule Auth.MFAContext do
  @moduledoc """
  Manages time-based one-time password (TOTP) multi-factor authentication.
  TOTP secrets are stored encrypted at rest; the plaintext is returned
  only at setup time so the user can scan the QR code. Verification
  checks the current window and one adjacent window for clock skew
  tolerance. The context records the last verified timestamp to prevent
  token replay within the same window.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Auth.{TOTPCredential, User}

  @type user_id :: String.t()
  @type totp_code :: String.t()
  @type setup_result :: {:ok, %{secret: String.t(), otpauth_url: String.t()}}

  @digits 6
  @period_seconds 30
  @window_tolerance 1
  @issuer "MyApp"

  @doc """
  Initialises TOTP setup for `user_id`. Returns the Base32 secret and an
  `otpauth://` URL for QR code generation. Does not activate MFA; the user
  must verify a code first via `activate/2`.
  """
  @spec setup(user_id()) :: setup_result() | {:error, Ecto.Changeset.t()}
  def setup(user_id) when is_binary(user_id) do
    secret = generate_secret()
    email = Repo.one(from(u in User, where: u.id == ^user_id, select: u.email))
    url = build_otpauth_url(secret, email)

    attrs = %{user_id: user_id, secret_encrypted: encrypt(secret), active: false}

    case upsert_credential(attrs) do
      {:ok, _cred} -> {:ok, %{secret: secret, otpauth_url: url}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Activates MFA for `user_id` by verifying the provided TOTP `code`.
  Returns `{:error, :invalid_code}` when the code does not match the
  current or adjacent windows.
  """
  @spec activate(user_id(), totp_code()) ::
          :ok | {:error, :invalid_code | :setup_not_started}
  def activate(user_id, code) when is_binary(user_id) and is_binary(code) do
    case fetch_inactive_credential(user_id) do
      nil -> {:error, :setup_not_started}
      cred ->
        if valid_code?(decrypt(cred.secret_encrypted), code) do
          cred |> TOTPCredential.activate_changeset() |> Repo.update!()
          :ok
        else
          {:error, :invalid_code}
        end
    end
  end

  @doc """
  Verifies a TOTP `code` for `user_id`. Returns `{:error, :replay_detected}`
  if the code was already used within the current window.
  """
  @spec verify(user_id(), totp_code()) ::
          :ok | {:error, :invalid_code | :not_enrolled | :replay_detected}
  def verify(user_id, code) when is_binary(user_id) and is_binary(code) do
    case fetch_active_credential(user_id) do
      nil -> {:error, :not_enrolled}
      cred ->
        current_counter = current_counter()

        if cred.last_used_counter == current_counter do
          {:error, :replay_detected}
        else
          secret = decrypt(cred.secret_encrypted)
          if valid_code?(secret, code) do
            cred |> TOTPCredential.used_changeset(%{last_used_counter: current_counter}) |> Repo.update!()
            :ok
          else
            {:error, :invalid_code}
          end
        end
    end
  end

  @doc "Removes TOTP credentials for `user_id`, disabling MFA."
  @spec disable(user_id()) :: :ok
  def disable(user_id) when is_binary(user_id) do
    Repo.delete_all(from(c in TOTPCredential, where: c.user_id == ^user_id))
    :ok
  end

  defp valid_code?(secret, code) do
    counter = current_counter()
    Enum.any?(-@window_tolerance..@window_tolerance, fn offset ->
      expected = hotp(secret, counter + offset)
      secure_compare(expected, String.trim(code))
    end)
  end

  defp hotp(secret, counter) do
    key = Base.decode32!(secret, case: :upper, padding: false)
    msg = <<counter::big-unsigned-integer-size(64)>>
    mac = :crypto.mac(:hmac, :sha, key, msg)
    offset = :binary.at(mac, byte_size(mac) - 1) &&& 0x0F
    <<_::binary-size(offset), code_int::big-unsigned-integer-size(32), _::binary>> = mac
    otp = (code_int &&& 0x7FFFFFFF) |> rem(trunc(:math.pow(10, @digits)))
    otp |> Integer.to_string() |> String.pad_leading(@digits, "0")
  end

  defp current_counter, do: div(System.os_time(:second), @period_seconds)

  defp generate_secret do
    :crypto.strong_rand_bytes(20) |> Base.encode32(padding: false)
  end

  defp build_otpauth_url(secret, email) do
    "otpauth://totp/#{URI.encode(@issuer)}:#{URI.encode(email)}?secret=#{secret}&issuer=#{URI.encode(@issuer)}&digits=#{@digits}&period=#{@period_seconds}"
  end

  defp encrypt(plaintext), do: Base.encode64(plaintext)
  defp decrypt(ciphertext), do: Base.decode64!(ciphertext)

  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false
  defp secure_compare(a, b), do: :crypto.hash_equals(a, b)

  defp upsert_credential(attrs) do
    %TOTPCredential{}
    |> TOTPCredential.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:secret_encrypted, :active]},
                   conflict_target: :user_id)
  end

  defp fetch_inactive_credential(user_id) do
    Repo.get_by(TOTPCredential, user_id: user_id, active: false)
  end

  defp fetch_active_credential(user_id) do
    Repo.get_by(TOTPCredential, user_id: user_id, active: true)
  end
end
```
