# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Auth.TokenBuilder.encode_claim_value/1`
- **Affected function(s):** `encode_claim_value/1`
- **Short explanation:** `encode_claim_value/1` calls `to_string/1` without any guard clause,
  relying implicitly on the `String.Chars` protocol. The function is used to flatten JWT claim
  values before they are Base64-encoded into the token payload. Strings, atoms, and integers
  pass through silently, but some produce misleading tokens (e.g., a boolean `:true` atom
  becomes the string `"true"`, losing type information), and others (e.g., a `Map` or `List`
  used as a multi-value claim) raise `Protocol.UndefinedError` at runtime, producing an
  unauthenticated response with no clear diagnostic.

---

```elixir
defmodule Auth.TokenBuilder do
  @moduledoc """
  Builds and signs compact JWT-like authentication tokens for internal
  service-to-service calls. Tokens are signed with HMAC-SHA256 and
  expire after a configurable TTL.

  Claim values are serialized to strings before signing to guarantee
  a stable, canonical representation across Elixir node restarts.
  """

  @default_ttl_seconds 3_600
  @delimiter "."
  @hash_algo :sha256

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Issues a signed token for `subject` carrying the given `claims` map.

  ## Options
    * `:ttl` - token lifetime in seconds (default: #{@default_ttl_seconds})

  ## Examples

      iex> Auth.TokenBuilder.issue("user:42", %{role: "admin"}, secret: "s3cr3t")
      {:ok, "eyJ..."}
  """
  def issue(subject, claims, opts) when is_binary(subject) and is_map(claims) do
    secret = Keyword.fetch!(opts, :secret)
    ttl    = Keyword.get(opts, :ttl, @default_ttl_seconds)

    now        = System.os_time(:second)
    expires_at = now + ttl

    base_claims = %{
      "sub" => subject,
      "iat" => now,
      "exp" => expires_at
    }

    merged = Map.merge(base_claims, encode_claims(claims))
    header = encode_header()
    payload = encode_payload(merged)
    signature = sign(header <> @delimiter <> payload, secret)

    {:ok, header <> @delimiter <> payload <> @delimiter <> signature}
  rescue
    e -> {:error, {:token_build_failed, Exception.message(e)}}
  end

  @doc """
  Verifies a token's signature and expiry. Returns `{:ok, claims}` or
  `{:error, reason}`.
  """
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    case String.split(token, @delimiter) do
      [header, payload, sig] ->
        expected = sign(header <> @delimiter <> payload, secret)

        if Plug.Crypto.secure_compare(sig, expected) do
          claims = decode_payload(payload)
          check_expiry(claims)
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  # ---------------------------------------------------------------------------
  # Encoding helpers
  # ---------------------------------------------------------------------------

  defp encode_header do
    %{"alg" => "HS256", "typ" => "JWT"}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_payload(claims) do
    claims
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_payload(encoded) do
    encoded
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp encode_claims(claims) do
    Map.new(claims, fn {k, v} ->
      {to_string(k), encode_claim_value(v)}
    end)
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because encode_claim_value/1 calls to_string/1
  # VALIDATION: with no guard clause or pattern matching on the input type.
  # VALIDATION: The function is intended to canonicalize JWT claim values, but
  # VALIDATION: it silently accepts any term that implements String.Chars. A
  # VALIDATION: boolean atom (:true / :false) becomes the string "true"/"false",
  # VALIDATION: discarding type semantics that JSON-aware decoders expect. An
  # VALIDATION: integer timestamp is coerced to a string, making numeric
  # VALIDATION: comparisons on the receiving end fail. Passing a List or Map
  # VALIDATION: (e.g., a roles list ["admin", "billing"]) raises
  # VALIDATION: Protocol.UndefinedError at runtime, bubbling up as a generic
  # VALIDATION: token_build_failed error with no indication of which claim
  # VALIDATION: caused the problem.
  defp encode_claim_value(value) do
    to_string(value)
  end
  # VALIDATION: SMELL END

  defp sign(data, secret) do
    :crypto.mac(:hmac, @hash_algo, secret, data)
    |> Base.url_encode64(padding: false)
  end

  defp check_expiry(%{"exp" => exp} = claims) do
    now = System.os_time(:second)

    if exp >= now do
      {:ok, claims}
    else
      {:error, :token_expired}
    end
  end

  defp check_expiry(_claims), do: {:error, :missing_expiry_claim}
end
```
