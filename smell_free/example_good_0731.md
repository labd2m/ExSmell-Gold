```elixir
defmodule Platform.SignedRequester do
  @moduledoc """
  An HTTP client wrapper that signs every outbound request with an HMAC
  signature over the method, path, timestamp, and body.

  Used for authenticating service-to-service calls where the receiving
  service verifies the signature before processing the request.
  """

  @type method :: :get | :post | :put | :patch | :delete
  @type response :: %{status: pos_integer(), body: term()}
  @type result :: {:ok, response()} | {:error, term()}
  @type credentials :: %{key_id: String.t(), secret: String.t()}

  @timestamp_header "x-timestamp"
  @key_id_header "x-key-id"
  @signature_header "x-signature"
  @default_timeout_ms 10_000

  @doc """
  Executes a signed GET request to `url` using `credentials`.
  """
  @spec get(String.t(), credentials(), keyword()) :: result()
  def get(url, credentials, opts \\ []) do
    signed_request(:get, url, nil, credentials, opts)
  end

  @doc """
  Executes a signed POST request with `body` using `credentials`.
  """
  @spec post(String.t(), map(), credentials(), keyword()) :: result()
  def post(url, body, credentials, opts \\ []) when is_map(body) do
    signed_request(:post, url, body, credentials, opts)
  end

  @doc """
  Executes a signed PUT request with `body` using `credentials`.
  """
  @spec put(String.t(), map(), credentials(), keyword()) :: result()
  def put(url, body, credentials, opts \\ []) when is_map(body) do
    signed_request(:put, url, body, credentials, opts)
  end

  @doc """
  Executes a signed DELETE request to `url` using `credentials`.
  """
  @spec delete(String.t(), credentials(), keyword()) :: result()
  def delete(url, credentials, opts \\ []) do
    signed_request(:delete, url, nil, credentials, opts)
  end

  defp signed_request(method, url, body, %{key_id: key_id, secret: secret}, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    extra_headers = Keyword.get(opts, :headers, [])
    timestamp = Integer.to_string(System.os_time(:second))
    encoded_body = encode_body(body)

    uri = URI.parse(url)
    path = uri.path || "/"
    signature = compute_signature(secret, method, path, timestamp, encoded_body)

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {@timestamp_header, timestamp},
        {@key_id_header, key_id},
        {@signature_header, signature}
      ] ++ extra_headers

    case Req.request(method: method, url: url, body: encoded_body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: decode_body(resp_body)}}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  defp compute_signature(secret, method, path, timestamp, body) do
    method_str = method |> Atom.to_string() |> String.upcase()
    body_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    signing_string = "#{method_str}\n#{path}\n#{timestamp}\n#{body_hash}"
    :crypto.mac(:hmac, :sha256, secret, signing_string) |> Base.encode64()
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{raw: body}
    end
  end

  defp decode_body(body) when is_map(body), do: body
  defp decode_body(_), do: %{}
end
```
