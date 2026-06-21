```elixir
defmodule Integrations.HttpClient do
  @moduledoc """
  A structured HTTP client for external service integrations.

  All configuration — base URL, auth token, timeout, and extra headers —
  is accepted as per-call options, making this client usable with multiple
  distinct upstream services from the same codebase without global state.
  """

  @type method :: :get | :post | :put | :patch | :delete
  @type response :: %{status: non_neg_integer(), body: term(), headers: [{String.t(), String.t()}]}
  @type client_error :: {:error, :timeout | :connection_refused | :bad_response | term()}
  @type result :: {:ok, response()} | client_error()

  @default_timeout_ms 10_000
  @default_headers [{"content-type", "application/json"}, {"accept", "application/json"}]

  @doc "Executes a GET request to `url`."
  @spec get(String.t(), keyword()) :: result()
  def get(url, opts \\ []) when is_binary(url) do
    request(:get, url, nil, opts)
  end

  @doc "Executes a POST request with a JSON-encoded `body`."
  @spec post(String.t(), map(), keyword()) :: result()
  def post(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    request(:post, url, body, opts)
  end

  @doc "Executes a PUT request with a JSON-encoded `body`."
  @spec put(String.t(), map(), keyword()) :: result()
  def put(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    request(:put, url, body, opts)
  end

  @doc "Executes a PATCH request with a JSON-encoded `body`."
  @spec patch(String.t(), map(), keyword()) :: result()
  def patch(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    request(:patch, url, body, opts)
  end

  @doc "Executes a DELETE request to `url`."
  @spec delete(String.t(), keyword()) :: result()
  def delete(url, opts \\ []) when is_binary(url) do
    request(:delete, url, nil, opts)
  end

  defp request(method, url, body, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    headers = build_headers(opts)
    encoded = encode_body(body)

    case Req.request(method: method, url: url, body: encoded, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok, %{status: status, body: decode_body(resp_body), headers: resp_headers}}

      {:error, %{reason: reason}} ->
        {:error, normalize_error(reason)}
    end
  end

  defp build_headers(opts) do
    extra = Keyword.get(opts, :headers, [])
    auth = build_auth_header(opts)
    @default_headers ++ auth ++ extra
  end

  defp build_auth_header(opts) do
    case Keyword.get(opts, :token) do
      nil -> []
      token when is_binary(token) -> [{"authorization", "Bearer #{token}"}]
    end
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
  defp decode_body(body), do: %{raw: body}

  defp normalize_error(:timeout), do: :timeout
  defp normalize_error(:econnrefused), do: :connection_refused
  defp normalize_error(other), do: {:unexpected, other}
end
```
