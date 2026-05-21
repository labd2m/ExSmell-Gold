# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `HttpClient.request/3`
- **Affected function(s):** `request/3`, `get/2`, `post/3`
- **Short explanation:** The library fetches `:timeout_ms` and `:max_redirects` from the global `Application Environment` rather than accepting them as call-site options. Any dependent application is locked into one global timeout for every HTTP call, making it impossible to use a short timeout for health-checks and a long timeout for file uploads within the same codebase without reconfiguring the whole application.

```elixir
defmodule HttpClient do
  @moduledoc """
  A lightweight HTTP client library built on top of `:httpc` for use in
  internal Elixir services. Handles retries, redirect following, and basic
  response parsing.

  Required configuration (config/config.exs):

      config :http_client,
        timeout_ms: 5_000,
        max_redirects: 5
  """

  require Logger

  @supported_methods [:get, :post, :put, :patch, :delete, :head]
  @default_headers [{"content-type", "application/json"}, {"accept", "application/json"}]

  @doc """
  Performs an HTTP request using the given method, URL, and optional body.
  Timeout and redirect limits are read from the application configuration.
  """
  @spec request(atom(), String.t(), map() | nil) ::
          {:ok, %{status: integer(), body: String.t(), headers: list()}}
          | {:error, term()}
  def request(method, url, body \\ nil)
      when method in @supported_methods and is_binary(url) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library reads :timeout_ms and
    # :max_redirects from the global Application Environment instead of
    # accepting them as keyword options in the function signature. Callers
    # in the same application cannot use different timeouts for different
    # requests (e.g., 500 ms for liveness probes vs 30 s for data exports).
    timeout_ms = Application.fetch_env!(:http_client, :timeout_ms)
    max_redirects = Application.fetch_env!(:http_client, :max_redirects)
    # VALIDATION: SMELL END

    headers = build_headers(method, body)
    encoded_body = encode_body(body)

    Logger.debug("[HttpClient] #{String.upcase(to_string(method))} #{url}")

    opts = [
      timeout: timeout_ms,
      connect_timeout: div(timeout_ms, 5),
      autoredirect: true
    ]

    case do_request(method, url, headers, encoded_body, opts, max_redirects) do
      {:ok, {{_vsn, status, _reason}, resp_headers, resp_body}} ->
        {:ok,
         %{
           status: status,
           body: to_string(resp_body),
           headers: normalize_headers(resp_headers)
         }}

      {:error, reason} ->
        Logger.warning("[HttpClient] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Convenience wrapper for GET requests."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(url, _opts \\ []) do
    request(:get, url, nil)
  end

  @doc "Convenience wrapper for POST requests."
  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, _opts \\ []) do
    request(:post, url, body)
  end

  @doc "Convenience wrapper for PUT requests."
  @spec put(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(url, body, _opts \\ []) do
    request(:put, url, body)
  end

  @doc """
  Parses a JSON response body. Returns `{:ok, term()}` or `{:error, reason}`.
  """
  @spec parse_json(%{body: String.t()}) :: {:ok, term()} | {:error, String.t()}
  def parse_json(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, "Failed to decode response body as JSON"}
    end
  end

  # --- Private helpers ---

  defp do_request(method, url, headers, body, opts, _max_redirects) do
    request_tuple =
      if body do
        {String.to_charlist(url), headers, "application/json", body}
      else
        {String.to_charlist(url), headers}
      end

    :httpc.request(method, request_tuple, opts, [])
  end

  defp build_headers(:get, _body), do: @default_headers
  defp build_headers(:head, _body), do: @default_headers

  defp build_headers(_method, nil), do: @default_headers

  defp build_headers(_method, _body) do
    [{"content-type", "application/json"} | @default_headers]
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body) when is_binary(body), do: body

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.downcase(to_string(k)), to_string(v)}
    end)
  end
end
```
