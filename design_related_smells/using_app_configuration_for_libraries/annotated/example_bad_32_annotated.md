# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `TokenGenerator.generate/0`
- **Affected function(s):** `generate/0`, `generate_otp/0`, `url_safe/0`
- **Short explanation:** The library reads `:token_length`, `:charset`, and `:otp_digits` from the global `Application` environment. This means a dependent application cannot generate tokens of different lengths (e.g., short OTPs vs. long session tokens) without changing the global config, defeating the purpose of a reusable library.

```elixir
defmodule TokenGenerator do
  @moduledoc """
  A library for generating cryptographically secure tokens and OTPs.

  Used for password resets, email verification, session identifiers,
  and one-time passcodes in authentication flows.

  Application configuration:

      config :token_generator,
        token_length:   32,
        charset:        :alphanumeric,   # :alphanumeric | :hex | :numeric | :base64
        otp_digits:     6,
        otp_expiry_sec: 300,
        url_safe:       true
  """

  @charsets %{
    alphanumeric: ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    hex:          ~c"0123456789abcdef",
    numeric:      ~c"0123456789",
    base64:       ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"
  }

  @doc """
  Generates a secure random token using the configured length and charset.

  Returns a string token.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because token_length, charset, and url_safe
  # are fetched from Application.fetch_env!/2 instead of being accepted as
  # parameters, so callers cannot request tokens of different sizes or
  # character sets within the same application.
  def generate do
    length   = Application.fetch_env!(:token_generator, :token_length)
    charset  = Application.fetch_env!(:token_generator, :charset)
    url_safe = Application.fetch_env!(:token_generator, :url_safe)
  # VALIDATION: SMELL END

    chars = Map.fetch!(@charsets, charset)

    token =
      length
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(fn byte -> Enum.at(chars, rem(byte, length(chars))) end)
      |> List.to_string()

    if url_safe do
      token
      |> String.replace("+", "-")
      |> String.replace("/", "_")
      |> String.replace("=", "")
    else
      token
    end
  end

  @doc """
  Generates a numeric OTP (One-Time Password) with a configured number of digits.

  Returns a zero-padded string.
  """
  def generate_otp do
    digits  = Application.fetch_env!(:token_generator, :otp_digits)
    max_val = trunc(:math.pow(10, digits))

    otp_value =
      :crypto.strong_rand_bytes(4)
      |> :binary.decode_unsigned()
      |> rem(max_val)

    String.pad_leading(Integer.to_string(otp_value), digits, "0")
  end

  @doc """
  Generates a secure token and wraps it in a metadata map with an expiry timestamp.
  """
  def generate_with_expiry do
    expiry_sec = Application.fetch_env!(:token_generator, :otp_expiry_sec)

    %{
      token:      generate(),
      expires_at: DateTime.utc_now() |> DateTime.add(expiry_sec, :second),
      issued_at:  DateTime.utc_now()
    }
  end

  @doc """
  Returns a URL-safe base64 token of the configured length.

  Regardless of the charset setting, this always uses base64url encoding.
  """
  def url_safe_token do
    length = Application.fetch_env!(:token_generator, :token_length)

    length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> String.slice(0, length)
  end

  @doc """
  Validates that a token string looks structurally valid (correct length and charset).

  Does NOT check expiry or database existence.
  """
  def valid_format?(token) when is_binary(token) do
    expected_length = Application.fetch_env!(:token_generator, :token_length)
    charset         = Application.fetch_env!(:token_generator, :charset)

    chars   = Map.fetch!(@charsets, charset)
    pattern = Enum.into(chars, MapSet.new())

    String.length(token) == expected_length and
      token
      |> String.graphemes()
      |> Enum.all?(fn c -> MapSet.member?(pattern, hd(String.to_charlist(c))) end)
  end

  @doc """
  Splits a compound token (e.g., `{user_id}.{token}`) and returns the parts.
  """
  def split_compound(compound_token) when is_binary(compound_token) do
    case String.split(compound_token, ".", parts: 2) do
      [id, token] -> {:ok, id, token}
      _           -> {:error, :invalid_format}
    end
  end
end
```
