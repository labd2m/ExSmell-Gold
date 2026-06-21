```elixir
defmodule Documents.SignedURLGenerator do
  @moduledoc """
  Generates time-limited signed URLs for private document downloads.
  Signatures use HMAC-SHA256 over the URL path and expiry timestamp.
  The verifier validates signatures and expiry without database lookups,
  keeping the hot download path stateless and horizontally scalable.
  """

  @hmac_algo :sha256
  @url_safe_chars ~r/[^a-zA-Z0-9\-._~]/

  @doc """
  Generates a signed URL for the document at `path`, valid for `ttl_seconds`.
  The signature is appended as query parameters `expires` and `sig`.
  """
  @spec generate(String.t(), pos_integer()) :: String.t()
  def generate(path, ttl_seconds \ 3_600)
      when is_binary(path) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    expires = System.os_time(:second) + ttl_seconds
    sig = sign(path, expires)
    "#{path}?expires=#{expires}&sig=#{URI.encode(sig)}"
  end

  @doc """
  Verifies a signed URL. Returns `{:ok, path}` when the signature is valid
  and the URL has not expired, or a typed error otherwise.
  """
  @spec verify(String.t()) :: {:ok, String.t()} | {:error, :expired | :invalid_signature}
  def verify(signed_url) when is_binary(signed_url) do
    uri = URI.parse(signed_url)
    params = URI.decode_query(uri.query || "")

    with {:ok, expires} <- parse_expires(params),
         {:ok, sig} <- fetch_sig(params),
         :ok <- check_expiry(expires),
         :ok <- verify_signature(uri.path, expires, sig) do
      {:ok, uri.path}
    end
  end

  @doc "Returns true when a signed URL is still valid at the current time."
  @spec valid?(String.t()) :: boolean()
  def valid?(signed_url) when is_binary(signed_url) do
    match?({:ok, _}, verify(signed_url))
  end

  defp sign(path, expires) do
    secret = fetch_secret()
    payload = "#{path}|#{expires}"
    :crypto.mac(:hmac, @hmac_algo, secret, payload) |> Base.url_encode64(padding: false)
  end

  defp verify_signature(path, expires, provided_sig) do
    expected = sign(path, expires)
    if secure_compare(provided_sig, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp parse_expires(%{"expires" => raw}) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_expires(_), do: {:error, :invalid_signature}

  defp fetch_sig(%{"sig" => sig}) when is_binary(sig) and byte_size(sig) > 0, do: {:ok, sig}
  defp fetch_sig(_), do: {:error, :invalid_signature}

  defp check_expiry(expires) do
    if System.os_time(:second) <= expires, do: :ok, else: {:error, :expired}
  end

  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false
  defp secure_compare(a, b), do: :crypto.hash_equals(a, b)

  defp fetch_secret, do: Application.fetch_env!(:my_app, :signed_url_secret)
end
```
