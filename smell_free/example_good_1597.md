```elixir
defmodule TwoFactor.TOTPSecret do
  @moduledoc """
  Generates and encodes TOTP secrets for multi-factor authentication enrollment.
  """

  @secret_byte_length 20

  @spec generate() :: String.t()
  def generate do
    @secret_byte_length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  @spec to_provisioning_uri(String.t(), String.t(), String.t()) :: String.t()
  def to_provisioning_uri(secret, account, issuer)
      when is_binary(secret) and is_binary(account) and is_binary(issuer) do
    encoded_account = URI.encode(account)
    encoded_issuer = URI.encode(issuer)

    "otpauth://totp/#{encoded_issuer}:#{encoded_account}" <>
      "?secret=#{secret}&issuer=#{encoded_issuer}&algorithm=SHA1&digits=6&period=30"
  end
end

defmodule TwoFactor.TOTP do
  @moduledoc """
  Verifies time-based one-time passwords against a stored Base32 secret.
  Accepts codes valid within a one-step drift window to tolerate clock skew.
  """

  @period 30
  @digits 6
  @drift_steps 1

  @spec verify(String.t(), String.t()) :: :ok | {:error, :invalid_code | :invalid_secret}
  def verify(secret, code) when is_binary(secret) and is_binary(code) do
    with {:ok, raw_secret} <- decode_secret(secret),
         true <- byte_size(raw_secret) > 0 do
      now_step = current_step()

      valid =
        Enum.any?(-@drift_steps..@drift_steps, fn drift ->
          expected = compute_totp(raw_secret, now_step + drift)
          secure_compare(expected, code)
        end)

      if valid, do: :ok, else: {:error, :invalid_code}
    else
      _ -> {:error, :invalid_secret}
    end
  end

  defp decode_secret(secret) do
    case Base.decode32(secret, padding: false, case: :mixed) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid_secret}
    end
  end

  defp current_step do
    System.os_time(:second) |> div(@period)
  end

  defp compute_totp(raw_secret, step) do
    step_bytes = <<step::big-unsigned-64>>
    mac = :crypto.mac(:hmac, :sha, raw_secret, step_bytes)
    offset = :binary.at(mac, byte_size(mac) - 1) |> band(0x0F)

    <<_::binary-size(offset), truncated::big-unsigned-32, _::binary>> = mac
    code = (truncated |> band(0x7FFFFFFF)) |> rem(:math.pow(10, @digits) |> round())
    String.pad_leading(Integer.to_string(code), @digits, "0")
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
  end

  defp secure_compare(_a, _b), do: false
end

defmodule TwoFactor.Enrollment do
  alias TwoFactor.TOTPSecret
  alias MyApp.Accounts.User
  alias MyApp.Repo

  @moduledoc """
  Manages the lifecycle of TOTP enrollment for user accounts,
  including secret generation, confirmation, and revocation.
  """

  @spec begin_enrollment(User.t()) :: {:ok, %{secret: String.t(), uri: String.t()}}
  def begin_enrollment(%User{email: email}) do
    secret = TOTPSecret.generate()
    uri = TOTPSecret.to_provisioning_uri(secret, email, "MyApp")
    {:ok, %{secret: secret, uri: uri}}
  end

  @spec confirm_enrollment(User.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_code | :invalid_secret}
  def confirm_enrollment(%User{} = user, secret, code) do
    with :ok <- TwoFactor.TOTP.verify(secret, code) do
      user
      |> Ecto.Changeset.change(totp_secret: secret, totp_enabled: true)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _cs} -> {:error, :invalid_code}
      end
    end
  end

  @spec revoke(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%User{} = user) do
    user
    |> Ecto.Changeset.change(totp_secret: nil, totp_enabled: false)
    |> Repo.update()
  end
end
```
