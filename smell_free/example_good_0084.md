# File: `example_good_84.md`

```elixir
defmodule Webhooks.SignatureVerifier do
  @moduledoc """
  Verifies HMAC-SHA256 signatures on inbound webhook payloads.

  Callers provide the raw request body, the signature header value,
  and the shared secret. Verification is timing-safe to prevent
  timing-oracle attacks.

  The module is stateless and does not read from the application
  environment; secrets are always passed explicitly as parameters.
  """

  @signature_prefix "sha256="
  @hash_algo :sha256

  @type raw_body :: binary()
  @type signature_header :: String.t()
  @type secret :: String.t()
  @type provider :: :github | :stripe | :shopify | :custom

  @type verify_result :: :ok | {:error, :invalid_signature | :malformed_header}

  @doc """
  Verifies the HMAC-SHA256 signature of a webhook payload.

  `signature_header` should be the raw value of the provider's signature
  header (e.g. `"sha256=abc123..."`).

  Returns `:ok` when the signature is valid, or `{:error, reason}`.
  """
  @spec verify(raw_body(), signature_header(), secret()) :: verify_result()
  def verify(body, signature_header, secret)
      when is_binary(body) and is_binary(signature_header) and is_binary(secret) do
    with {:ok, claimed_digest} <- extract_digest(signature_header),
         {:ok, claimed_bytes} <- decode_hex(claimed_digest) do
      compare_signatures(body, claimed_bytes, secret)
    end
  end

  @doc """
  Parses a raw webhook body as JSON after verifying the signature.

  Returns `{:ok, parsed_map}` on success, or an error tuple describing
  the first failure encountered.
  """
  @spec verify_and_parse(raw_body(), signature_header(), secret()) ::
          {:ok, map()} | {:error, :invalid_signature | :malformed_header | :invalid_json}
  def verify_and_parse(body, signature_header, secret)
      when is_binary(body) and is_binary(signature_header) and is_binary(secret) do
    with :ok <- verify(body, signature_header, secret),
         {:ok, parsed} <- parse_json(body) do
      {:ok, parsed}
    end
  end

  @doc """
  Generates the expected signature header value for `body` signed with
  `secret`. Useful for constructing test fixtures and outbound webhooks.
  """
  @spec sign(raw_body(), secret()) :: signature_header()
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    digest = compute_digest(body, secret)
    @signature_prefix <> Base.encode16(digest, case: :lower)
  end

  @doc """
  Returns the canonical header name used by a known webhook provider.
  """
  @spec header_name(provider()) :: String.t()
  def header_name(:github), do: "x-hub-signature-256"
  def header_name(:stripe), do: "stripe-signature"
  def header_name(:shopify), do: "x-shopify-hmac-sha256"
  def header_name(:custom), do: "x-signature"

  defp extract_digest(header) do
    case header do
      @signature_prefix <> digest when byte_size(digest) > 0 ->
        {:ok, digest}

      _ ->
        {:error, :malformed_header}
    end
  end

  defp decode_hex(hex_string) do
    case Base.decode16(hex_string, case: :mixed) do
      {:ok, _bytes} = ok -> ok
      :error -> {:error, :malformed_header}
    end
  end

  defp compare_signatures(body, claimed_bytes, secret) do
    expected_bytes = compute_digest(body, secret)

    if :crypto.hash_equals(expected_bytes, claimed_bytes) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp compute_digest(body, secret) do
    :crypto.mac(:hmac, @hash_algo, secret, body)
  end

  defp parse_json(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end
end
```
