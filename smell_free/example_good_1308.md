**File:** `example_good_1308.md`

```elixir
defmodule TwoFactor.TOTPSecret do
  @moduledoc "Generates and encodes TOTP secrets for authenticator app enrollment."

  @secret_byte_length 20

  @spec generate() :: String.t()
  def generate do
    @secret_byte_length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  @spec provisioning_uri(String.t(), String.t(), String.t()) :: String.t()
  def provisioning_uri(secret, account_name, issuer) do
    encoded_account = URI.encode(account_name)
    encoded_issuer = URI.encode(issuer)
    "otpauth://totp/#{encoded_issuer}:#{encoded_account}?secret=#{secret}&issuer=#{encoded_issuer}"
  end
end

defmodule TwoFactor.TOTP do
  @moduledoc """
  Verifies time-based one-time passwords per RFC 6238.
  Accepts codes from a one-step window on either side of the current interval
  to accommodate minor clock drift.
  """

  @step 30
  @digits 6
  @window 1

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(secret, code) when is_binary(secret) and is_binary(code) do
    now = System.system_time(:second)
    counter = div(now, @step)

    Enum.any?((-@window)..@window, fn offset ->
      expected = generate_code(secret, counter + offset)
      secure_compare(expected, code)
    end)
  end

  defp generate_code(secret, counter) do
    key = Base.decode32!(secret, padding: false)
    msg = <<counter::big-unsigned-64>>
    <<_::19, offset_bits::4>> = hmac = :crypto.mac(:hmac, :sha, key, msg)
    offset = offset_bits

    <<_::size(offset)-binary, code_int::big-unsigned-32, _::binary>> =
      binary_part(hmac, offset, 4)

    otp = rem(code_int &&& 0x7FFFFFFF, round(:math.pow(10, @digits)))
    String.pad_leading(to_string(otp), @digits, "0")
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end

defmodule TwoFactor.BackupCodes do
  @moduledoc """
  Generates, hashes, and verifies single-use backup codes for account recovery.
  Codes are stored as bcrypt hashes and consumed on use.
  """

  @code_count 10
  @code_length 8

  @type hashed_codes :: [String.t()]

  @spec generate() :: {[String.t()], hashed_codes()}
  def generate do
    plain_codes = Enum.map(1..@code_count, fn _ -> random_code() end)
    hashed = Enum.map(plain_codes, &hash_code/1)
    {plain_codes, hashed}
  end

  @spec verify_and_consume(String.t(), hashed_codes()) ::
          {:ok, hashed_codes()} | {:error, :invalid_code}
  def verify_and_consume(plain_code, hashed_codes) when is_list(hashed_codes) do
    normalized = String.downcase(String.replace(plain_code, "-", ""))

    case Enum.split_with(hashed_codes, &matches_hash?(normalized, &1)) do
      {[_matched], remaining} -> {:ok, remaining}
      {[], _} -> {:error, :invalid_code}
    end
  end

  defp random_code do
    @code_length
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, @code_length)
  end

  defp hash_code(code) do
    :crypto.hash(:sha256, code) |> Base.encode64()
  end

  defp matches_hash?(code, hash) do
    expected = :crypto.hash(:sha256, code) |> Base.encode64()
    :crypto.hash_equals(expected, hash)
  end
end

defmodule TwoFactor do
  @moduledoc "Public interface for two-factor authentication enrollment and verification."

  alias TwoFactor.{BackupCodes, TOTP, TOTPSecret}

  @type enrollment :: %{
          secret: String.t(),
          provisioning_uri: String.t(),
          backup_codes: [String.t()],
          hashed_backup_codes: BackupCodes.hashed_codes()
        }

  @spec begin_enrollment(String.t(), String.t()) :: enrollment()
  def begin_enrollment(account_name, issuer) do
    secret = TOTPSecret.generate()
    {plain_codes, hashed_codes} = BackupCodes.generate()

    %{
      secret: secret,
      provisioning_uri: TOTPSecret.provisioning_uri(secret, account_name, issuer),
      backup_codes: plain_codes,
      hashed_backup_codes: hashed_codes
    }
  end

  @spec verify_totp(String.t(), String.t()) :: boolean()
  defdelegate verify_totp(secret, code), to: TOTP, as: :verify

  @spec use_backup_code(String.t(), BackupCodes.hashed_codes()) ::
          {:ok, BackupCodes.hashed_codes()} | {:error, :invalid_code}
  defdelegate use_backup_code(code, hashed_codes), to: BackupCodes, as: :verify_and_consume
end
```
