# File: `example_good_208.md`

```elixir
defmodule Auth.MfaValidator do
  @moduledoc """
  Validates Time-based One-Time Passwords (TOTP) for multi-factor
  authentication using RFC 6238.

  Codes are checked against a configurable time window to tolerate
  minor clock skew between the authenticator app and the server.
  Used codes are tracked via a caller-supplied check to prevent
  replay attacks within the validity window.
  """

  @digits 6
  @period 30
  @default_window 1
  @hash_algo :sha

  @type secret :: binary()
  @type totp_code :: String.t()
  @type used_check_fn :: (String.t() -> boolean())
  @type mark_used_fn :: (String.t() -> :ok)

  @type verify_opts :: [
          window: non_neg_integer(),
          used?: used_check_fn(),
          mark_used: mark_used_fn()
        ]

  @type verify_result :: :ok | {:error, :invalid_code | :replayed_code}

  @doc """
  Verifies a TOTP code against `secret` at the current server time.

  The `:window` option (default: 1) allows codes from that many periods
  before and after the current period, accommodating clock skew.

  Supply `:used?` and `:mark_used` functions to enable replay protection.
  When `:used?` is not provided, replay protection is skipped.

  Returns `:ok` on success or a tagged error atom.
  """
  @spec verify(secret(), totp_code(), verify_opts()) :: verify_result()
  def verify(secret, code, opts \\ [])
      when is_binary(secret) and is_binary(code) do
    window = Keyword.get(opts, :window, @default_window)
    used? = Keyword.get(opts, :used?, fn _code -> false end)
    mark_used = Keyword.get(opts, :mark_used, fn _code -> :ok end)

    counter = current_counter()

    valid_counters = for offset <- -window..window, do: counter + offset

    case find_matching_counter(secret, code, valid_counters) do
      nil ->
        {:error, :invalid_code}

      matching_counter ->
        check_and_consume_code(code, matching_counter, used?, mark_used)
    end
  end

  @doc """
  Generates the current TOTP code for a secret, useful for testing
  or displaying codes in authenticator provisioning flows.
  """
  @spec generate(secret()) :: totp_code()
  def generate(secret) when is_binary(secret) do
    compute_totp(secret, current_counter())
  end

  @doc """
  Generates a cryptographically random TOTP secret encoded in Base32.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    :crypto.strong_rand_bytes(20) |> Base.encode32(padding: false)
  end

  @doc """
  Builds an `otpauth://` URI suitable for encoding into a QR code for
  authenticator app provisioning.
  """
  @spec otpauth_uri(String.t(), String.t(), String.t()) :: String.t()
  def otpauth_uri(issuer, account_name, secret_base32)
      when is_binary(issuer) and is_binary(account_name) and is_binary(secret_base32) do
    label = URI.encode("#{issuer}:#{account_name}")

    params =
      URI.encode_query(%{
        "secret" => secret_base32,
        "issuer" => issuer,
        "algorithm" => "SHA1",
        "digits" => @digits,
        "period" => @period
      })

    "otpauth://totp/#{label}?#{params}"
  end

  defp find_matching_counter(secret, code, counters) do
    Enum.find(counters, fn counter ->
      expected = compute_totp(secret, counter)
      :crypto.hash_equals(expected, code)
    end)
  end

  defp check_and_consume_code(code, _counter, used?, mark_used) do
    if used?.(code) do
      {:error, :replayed_code}
    else
      mark_used.(code)
      :ok
    end
  end

  defp compute_totp(secret, counter) do
    decoded_secret = Base.decode32!(secret, padding: false)
    counter_bytes = <<counter::unsigned-big-integer-64>>
    hmac = :crypto.mac(:hmac, @hash_algo, decoded_secret, counter_bytes)
    offset = :binary.at(hmac, byte_size(hmac) - 1) &&& 0x0F
    <<_::binary-size(offset), truncated::unsigned-big-integer-32, _::binary>> = hmac
    code = (truncated &&& 0x7FFFFFFF) |> rem(Integer.pow(10, @digits))
    String.pad_leading(Integer.to_string(code), @digits, "0")
  end

  defp current_counter do
    System.system_time(:second) |> div(@period)
  end
end
```
