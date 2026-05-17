# Annotated Example 09

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Auth.BearerTokenExtractor.extract_token/1`
- **Affected function(s):** `extract_token/1`
- **Short explanation:** The function splits the `Authorization` header value on `" "` (a single
  space) and grabs the token at index 1 using `Enum.at/2`. This silently mishandles several real
  inputs: headers with multiple spaces (`"Bearer  <token>"`), unsupported schemes
  (`"Basic dXNlcjpwYXNz"`), or completely malformed strings. In each case the function returns
  `{:ok, wrong_value}` — `nil`, an empty string, or the wrong segment — instead of returning
  `{:error, reason}` and forcing the caller to deal with the failure.

---

```elixir
defmodule Auth.BearerTokenExtractor do
  @moduledoc """
  Extracts and validates Bearer tokens from HTTP `Authorization` headers.

  This module is used by the API gateway plug pipeline to authenticate
  inbound requests before they reach controller actions.

  Expected header format:
    Authorization: Bearer <opaque_token>

  The token is a URL-safe Base64-encoded, signed JWT issued by the
  internal identity service.
  """

  require Logger

  @token_min_length 32
  @token_max_length 4096

  @doc """
  Extracts the raw Bearer token string from an `Authorization` header value.

  Returns `{:ok, token}` on success, or `{:error, reason}` if the header
  is missing, malformed, or uses an unsupported authentication scheme.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits on a single space and
  # VALIDATION: uses `Enum.at(parts, 1)` to extract the token without pattern matching.
  # VALIDATION: If the header uses a different scheme ("Basic dXNlcjpwYXNz"),
  # VALIDATION: the function returns {:ok, "dXNlcjpwYXNz"} — the Base64 credentials —
  # VALIDATION: as if it were a valid Bearer token. Similarly, "Bearer  token" (two
  # VALIDATION: spaces) returns {:ok, ""} and "Bearer" with no token returns {:ok, nil}.
  # VALIDATION: None of these cases crash; they all silently produce an incorrect result.
  def extract_token(authorization_header)

  def extract_token(nil), do: {:error, :missing_authorization_header}

  def extract_token(header) when is_binary(header) do
    parts = String.split(header, " ")
    token = Enum.at(parts, 1)

    {:ok, token}
  end
  # VALIDATION: SMELL END

  @doc """
  Validates the structural properties of an extracted token string.

  Does NOT verify the signature — that is the responsibility of
  `Auth.TokenVerifier.verify/2`.
  """
  def validate_token_structure(token) when is_binary(token) do
    cond do
      byte_size(token) < @token_min_length ->
        {:error, :token_too_short}

      byte_size(token) > @token_max_length ->
        {:error, :token_too_long}

      not url_safe_base64?(token) and not jwt_format?(token) ->
        {:error, :invalid_token_encoding}

      true ->
        :ok
    end
  end

  def validate_token_structure(_), do: {:error, :invalid_token_type}

  @doc """
  Convenience function: extract + validate in one call.

  Used by the authentication plug for the fast path.
  """
  def extract_and_validate(authorization_header) do
    with {:ok, token}  <- extract_token(authorization_header),
         :ok           <- validate_token_structure(token) do
      {:ok, token}
    end
  end

  @doc """
  Redacts a token for safe inclusion in log output.

  Shows only the first 8 and last 4 characters, masking the rest.
  """
  def redact(token) when is_binary(token) and byte_size(token) >= 12 do
    prefix = String.slice(token, 0, 8)
    suffix = String.slice(token, -4, 4)
    masked = String.duplicate("*", min(byte_size(token) - 12, 24))
    "#{prefix}#{masked}#{suffix}"
  end

  def redact(_), do: "***REDACTED***"

  @doc """
  Returns the authentication scheme from a raw header value.

  Expected to be "Bearer" for this extractor. Used in diagnostics.
  """
  def scheme(header) when is_binary(header) do
    header
    |> String.split(" ", parts: 2)
    |> List.first()
    |> String.upcase()
  end

  def scheme(_), do: "UNKNOWN"

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp url_safe_base64?(str) do
    Regex.match?(~r/\A[A-Za-z0-9\-_]+=*\z/, str)
  end

  defp jwt_format?(str) do
    # JWTs are three Base64url segments separated by "."
    Regex.match?(~r/\A[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]*\z/, str)
  end
end
```
