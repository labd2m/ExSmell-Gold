```elixir
defmodule Platform.SignedUrl do
  @moduledoc """
  Generates and verifies HMAC-signed, time-limited URLs for secure resource access.

  Signed URLs are self-contained: the expiry timestamp and an HMAC signature
  are embedded as query parameters. Verification requires only the signing
  key — no database lookup or shared state.
  """

  @type url :: String.t()
  @type opts :: [expires_in: pos_integer(), extra_claims: map()]
  @type verify_result :: {:ok, %{path: String.t(), claims: map()}} | {:error, :expired | :invalid_signature | :malformed}

  @signature_param "_sig"
  @expires_param "_exp"
  @default_expires_in_seconds 900

  @doc """
  Generates a signed URL for `path`.

  The `expires_in` option controls validity in seconds (default 15 minutes).
  `extra_claims` are additional values embedded in the signature scope and
  returned verbatim on successful verification.
  """
  @spec sign(String.t(), url(), opts()) :: url()
  def sign(secret, path, opts \\ []) when is_binary(secret) and is_binary(path) do
    expires_in = Keyword.get(opts, :expires_in, @default_expires_in_seconds)
    extra_claims = Keyword.get(opts, :extra_claims, %{})
    expires_at = System.os_time(:second) + expires_in

    claims = Map.put(extra_claims, :exp, expires_at)
    claims_encoded = encode_claims(claims)
    signature = compute_signature(secret, path, claims_encoded)

    uri = URI.parse(path)
    existing_query = URI.decode_query(uri.query || "")

    new_query =
      existing_query
      |> Map.put(@expires_param, claims_encoded)
      |> Map.put(@signature_param, signature)
      |> URI.encode_query()

    %{uri | query: new_query} |> URI.to_string()
  end

  @doc """
  Verifies a signed URL. Returns `{:ok, %{path: path, claims: claims}}` on success
  or `{:error, reason}` if the signature is invalid or the URL has expired.
  """
  @spec verify(String.t(), url()) :: verify_result()
  def verify(secret, signed_url) when is_binary(secret) and is_binary(signed_url) do
    with {:ok, uri, query} <- parse_url(signed_url),
         {:ok, claims_encoded, received_sig} <- extract_params(query),
         {:ok, claims} <- decode_claims(claims_encoded),
         :ok <- check_expiry(claims),
         :ok <- verify_signature(secret, clean_path(uri), claims_encoded, received_sig) do
      {:ok, %{path: clean_path(uri), claims: Map.delete(claims, :exp)}}
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    {:ok, uri, query}
  rescue
    _ -> {:error, :malformed}
  end

  defp extract_params(query) do
    case {Map.get(query, @expires_param), Map.get(query, @signature_param)} do
      {nil, _} -> {:error, :malformed}
      {_, nil} -> {:error, :malformed}
      {exp, sig} -> {:ok, exp, sig}
    end
  end

  defp decode_claims(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} <- Jason.decode(json, keys: :atoms) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(%{exp: exp}) when is_integer(exp) do
    if System.os_time(:second) <= exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :malformed}

  defp verify_signature(secret, path, claims_encoded, received_sig) do
    expected = compute_signature(secret, path, claims_encoded)
    if Plug.Crypto.secure_compare(expected, received_sig), do: :ok, else: {:error, :invalid_signature}
  end

  defp compute_signature(secret, path, claims_encoded) do
    :crypto.mac(:hmac, :sha256, secret, "#{path}:#{claims_encoded}")
    |> Base.url_encode64(padding: false)
  end

  defp encode_claims(claims) do
    claims |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp clean_path(uri) do
    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop([@signature_param, @expires_param])

    %{uri | query: if(map_size(query) == 0, do: nil, else: URI.encode_query(query))}
    |> URI.to_string()
  end
end
```
