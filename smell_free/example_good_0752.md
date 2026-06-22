```elixir
defmodule Cdn.SignedUrl do
  @moduledoc """
  Generates and verifies time-limited, HMAC-signed CDN URLs in the style
  of AWS CloudFront canned policies.

  A signed URL embeds an expiry timestamp and an HMAC-SHA256 signature
  over `(url, expiry)` so that tampering with either the resource path or
  the expiry window invalidates the signature. Verification is timing-safe.
  """

  @separator "~"

  @type sign_opts :: [ttl_seconds: pos_integer(), key_id: String.t() | nil]

  @spec sign(String.t(), binary(), sign_opts()) :: String.t()
  def sign(url, secret, opts \\ []) when is_binary(url) and is_binary(secret) do
    ttl = Keyword.get(opts, :ttl_seconds, 3_600)
    key_id = Keyword.get(opts, :key_id)
    expires_at = System.system_time(:second) + ttl

    signature = compute_signature(url, expires_at, secret)

    params =
      %{"Expires" => expires_at, "Signature" => signature}
      |> then(fn p -> if key_id, do: Map.put(p, "Key-Pair-Id", key_id), else: p end)
      |> URI.encode_query()

    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}#{params}"
  end

  @spec verify(String.t(), binary()) ::
          {:ok, String.t()} | {:error, :expired | :invalid_signature | :malformed}
  def verify(signed_url, secret) when is_binary(signed_url) and is_binary(secret) do
    with {:ok, base_url, params} <- parse_signed_url(signed_url),
         {:ok, expires_at} <- extract_expiry(params),
         {:ok, signature} <- extract_signature(params),
         :ok <- check_expiry(expires_at),
         :ok <- verify_signature(base_url, expires_at, signature, secret) do
      {:ok, base_url}
    end
  end

  @spec valid?(String.t(), binary()) :: boolean()
  def valid?(signed_url, secret) do
    match?({:ok, _}, verify(signed_url, secret))
  end

  defp compute_signature(url, expires_at, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{url}#{@separator}#{expires_at}")
    |> Base.url_encode64(padding: false)
  end

  defp parse_signed_url(signed_url) do
    case String.split(signed_url, "?", parts: 2) do
      [base, query_string] ->
        params = URI.decode_query(query_string)
        clean_url = base <> "?" <> remove_signing_params(query_string)
        {:ok, clean_url |> String.trim_trailing("?"), params}

      [base] ->
        {:ok, base, %{}}

      _ ->
        {:error, :malformed}
    end
  end

  defp remove_signing_params(query_string) do
    signing_keys = ~w(Expires Signature Key-Pair-Id)

    query_string
    |> URI.decode_query()
    |> Map.drop(signing_keys)
    |> URI.encode_query()
  end

  defp extract_expiry(%{"Expires" => exp_str}) do
    case Integer.parse(exp_str) do
      {exp, ""} -> {:ok, exp}
      _ -> {:error, :malformed}
    end
  end

  defp extract_expiry(_), do: {:error, :malformed}

  defp extract_signature(%{"Signature" => sig}), do: {:ok, sig}
  defp extract_signature(_), do: {:error, :malformed}

  defp check_expiry(expires_at) do
    if System.system_time(:second) <= expires_at, do: :ok, else: {:error, :expired}
  end

  defp verify_signature(base_url, expires_at, provided_sig, secret) do
    expected = compute_signature(base_url, expires_at, secret)

    with {:ok, expected_bytes} <- Base.url_decode64(expected, padding: false),
         {:ok, provided_bytes} <- Base.url_decode64(provided_sig, padding: false),
         true <- :crypto.hash_equals(expected_bytes, provided_bytes) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end
end
```
