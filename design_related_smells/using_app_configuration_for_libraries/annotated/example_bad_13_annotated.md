# Annotated Example 13

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `TokenGenerator.generate/0`
- **Affected function(s):** `generate/0`
- **Short explanation:** `TokenGenerator.generate/0` reads `:token_length` from the application environment instead of accepting the desired length as a function parameter or keyword option. This forces the entire application to use one token length, making it impossible to generate short confirmation codes (e.g., 6 chars) and long API keys (e.g., 64 chars) from the same library without mutating global state.

## Code

```elixir
defmodule TokenGenerator do
  @moduledoc """
  A library for generating cryptographically secure random tokens suitable
  for use as API keys, password-reset links, email confirmation codes, and
  session identifiers.

  Configure in `config/config.exs`:

      config :token_generator,
        token_length: 32,
        encoding: :hex
  """

  @supported_encodings [:hex, :base64, :base64url]

  @doc """
  Generates a secure random token.

  Token length (in bytes before encoding) and encoding format are read from
  the application environment. The final string length will vary depending on
  the encoding chosen.

  Returns a binary string.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because token_length and encoding are fetched from
  # the Application Environment rather than being optional parameters. Callers that
  # need different token sizes (e.g., short SMS codes vs. long API keys) cannot
  # use this function with different lengths within the same application.
  def generate do
    length = Application.fetch_env!(:token_generator, :token_length)
    encoding = Application.get_env(:token_generator, :encoding, :hex)

    unless encoding in @supported_encodings do
      raise ArgumentError, "unsupported encoding #{inspect(encoding)}"
    end

    length
    |> :crypto.strong_rand_bytes()
    |> encode(encoding)
  end
  # VALIDATION: SMELL END

  @doc """
  Generates a token and returns `{:ok, token}` or `{:error, reason}`.
  """
  def safe_generate do
    {:ok, generate()}
  rescue
    e in ArgumentError -> {:error, e.message}
    _ -> {:error, "token generation failed"}
  end

  @doc """
  Generates a token and stores it alongside the given metadata map.
  Returns `{token, metadata}` where metadata includes a generated timestamp.
  """
  def generate_with_metadata(metadata \\ %{}) when is_map(metadata) do
    token = generate()
    issued_at = DateTime.utc_now()
    expires_at = DateTime.add(issued_at, ttl_seconds(), :second)

    enriched =
      metadata
      |> Map.put(:token, token)
      |> Map.put(:issued_at, issued_at)
      |> Map.put(:expires_at, expires_at)

    {token, enriched}
  end

  @doc """
  Returns true if the token appears structurally valid (non-empty binary).
  Does not perform cryptographic verification.
  """
  def valid_format?(token) when is_binary(token) and byte_size(token) > 0, do: true
  def valid_format?(_), do: false

  @doc """
  Compares two tokens in constant time to prevent timing attacks.
  """
  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and
      :crypto.hash(:sha256, left) == :crypto.hash(:sha256, right)
  end

  def secure_compare(_, _), do: false

  ## Private helpers

  defp encode(bytes, :hex), do: Base.encode16(bytes, case: :lower)
  defp encode(bytes, :base64), do: Base.encode64(bytes)
  defp encode(bytes, :base64url), do: Base.url_encode64(bytes, padding: false)

  defp ttl_seconds do
    Application.get_env(:token_generator, :ttl_seconds, 3_600)
  end
end
```
