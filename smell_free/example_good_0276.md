```elixir
defmodule MyApp.Accounts.TwoFactorAuth do
  @moduledoc """
  Implements TOTP-based two-factor authentication conforming to RFC 6238.
  Secret generation, QR code URI construction, and code verification are
  provided as a pure functional API backed by the `NimbleTOTP` library.

  Verified backup codes are single-use; each call to `verify_backup_code/2`
  that succeeds consumes the code by returning the updated remaining set.
  """

  @issuer "MyApp"
  @backup_code_count 10
  @backup_code_length 8
  @totp_window 1

  @type secret :: binary()
  @type totp_code :: String.t()
  @type backup_code :: String.t()

  @doc """
  Generates a new cryptographically random TOTP secret.
  Store this value (encrypted at rest) against the user record.
  """
  @spec generate_secret() :: secret()
  def generate_secret, do: NimbleTOTP.secret()

  @doc """
  Returns the `otpauth://` URI used to provision an authenticator app.
  Pass this to a QR code library to render the enrollment QR code.
  """
  @spec provisioning_uri(secret(), String.t()) :: String.t()
  def provisioning_uri(secret, account_name) when is_binary(account_name) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{account_name}", secret, issuer: @issuer)
  end

  @doc """
  Verifies a 6-digit TOTP `code` against `secret` with a one-step window
  on either side of the current 30-second period to allow for clock drift.
  """
  @spec verify_totp(secret(), totp_code()) :: boolean()
  def verify_totp(secret, code) when is_binary(code) do
    NimbleTOTP.valid?(secret, code, window: @totp_window)
  end

  @doc """
  Generates a set of one-time backup codes for account recovery.
  Each code is a random uppercase alphanumeric string formatted as
  two groups of four characters (e.g. `"ABCD-1234"`).
  """
  @spec generate_backup_codes() :: [backup_code()]
  def generate_backup_codes do
    Enum.map(1..@backup_code_count, fn _ -> random_backup_code() end)
  end

  @doc """
  Checks whether `code` exists in `remaining_codes`. On success, returns
  `{:ok, updated_codes}` with the matched code removed. On failure,
  returns `{:error, :invalid_backup_code}`.
  """
  @spec verify_backup_code(backup_code(), [backup_code()]) ::
          {:ok, [backup_code()]} | {:error, :invalid_backup_code}
  def verify_backup_code(code, remaining_codes)
      when is_binary(code) and is_list(remaining_codes) do
    normalised = String.upcase(String.replace(code, "-", ""))

    index =
      Enum.find_index(remaining_codes, fn stored ->
        stored_normalised = String.upcase(String.replace(stored, "-", ""))
        secure_compare(stored_normalised, normalised)
      end)

    case index do
      nil ->
        {:error, :invalid_backup_code}

      i ->
        updated = List.delete_at(remaining_codes, i)
        {:ok, updated}
    end
  end

  @doc "Returns the number of backup codes remaining."
  @spec backup_codes_remaining([backup_code()]) :: non_neg_integer()
  def backup_codes_remaining(codes) when is_list(codes), do: length(codes)

  @spec random_backup_code() :: backup_code()
  defp random_backup_code do
    chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    raw = Enum.map_join(1..@backup_code_length, fn _ ->
      :binary.at(chars, :rand.uniform(byte_size(chars)) - 1) |> List.wrap() |> IO.iodata_to_binary()
    end)
    "#{String.slice(raw, 0, 4)}-#{String.slice(raw, 4, 4)}"
  end

  @spec secure_compare(String.t(), String.t()) :: boolean()
  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp secure_compare(a, b) do
    :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
  end
end
```
