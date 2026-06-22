```elixir
defmodule Integrations.HTTPClient do
  @moduledoc """
  A structured wrapper around outbound HTTP requests.
  All responses are normalized to tagged result tuples. Transport errors,
  server errors, and client errors are distinguished so callers can apply
  targeted retry or fallback logic.
  """

  require Logger

  @type method :: :get | :post | :put | :patch | :delete
  @type headers :: list({String.t(), String.t()})
  @type response :: {:ok, %{status: integer(), body: term(), headers: headers()}} | {:error, error_reason()}
  @type error_reason :: :timeout | :connection_refused | :unknown_transport_error

  @default_timeout_ms 10_000
  @json_content_type "application/json"

  @spec get(String.t(), headers(), keyword()) :: response()
  def get(url, headers \\ [], opts \\ []) when is_binary(url) do
    request(:get, url, nil, headers, opts)
  end

  @spec post(String.t(), term(), headers(), keyword()) :: response()
  def post(url, body, headers \\ [], opts \\ []) when is_binary(url) do
    request(:post, url, body, headers, opts)
  end

  @spec put(String.t(), term(), headers(), keyword()) :: response()
  def put(url, body, headers \\ [], opts \\ []) when is_binary(url) do
    request(:put, url, body, headers, opts)
  end

  @spec delete(String.t(), headers(), keyword()) :: response()
  def delete(url, headers \\ [], opts \\ []) when is_binary(url) do
    request(:delete, url, nil, headers, opts)
  end

  defp request(method, url, body, headers, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    encoded = encode_body(body)
    all_headers = base_headers() ++ headers

    case :hackney.request(method, url, all_headers, encoded, recv_timeout: timeout) do
      {:ok, status, resp_headers, ref} ->
        build_response(status, resp_headers, ref)

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :econnrefused} ->
        {:error, :connection_refused}

      {:error, reason} ->
        Logger.warning("HTTP request failed", method: method, url: url, reason: inspect(reason))
        {:error, :unknown_transport_error}
    end
  end

  defp build_response(status, resp_headers, ref) do
    with {:ok, raw_body} <- :hackney.body(ref) do
      {:ok, %{status: status, body: decode_body(raw_body, resp_headers), headers: resp_headers}}
    end
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Jason.encode!(body)

  defp decode_body(raw, headers) do
    if json_response?(headers) do
      case Jason.decode(raw) do
        {:ok, decoded} -> decoded
        {:error, _} -> raw
      end
    else
      raw
    end
  end

  defp json_response?(headers) do
    Enum.any?(headers, fn {k, v} ->
      String.downcase(k) == "content-type" and String.contains?(v, @json_content_type)
    end)
  end

  defp base_headers do
    [{"Content-Type", @json_content_type}, {"Accept", @json_content_type}]
  end
end
```
