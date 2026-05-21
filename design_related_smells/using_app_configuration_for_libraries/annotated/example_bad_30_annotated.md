# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `HttpClient.request/3`
- **Affected function(s):** `request/3`, `get/2`, `post/3`, `put/3`, `delete/2`
- **Short explanation:** The library reads `:timeout`, `:retry_count`, `:retry_delay_ms`, and `:follow_redirects` from the global `Application` environment. All HTTP calls from any consumer of this library must share the same timeout and retry settings, making it impossible to have a fast timeout for health checks and a longer timeout for file uploads in the same application.

```elixir
defmodule HttpClient do
  @moduledoc """
  A lightweight HTTP client library for making outbound HTTP requests.

  Provides consistent error handling, automatic retries with backoff,
  and request/response logging for production service-to-service calls.

  Application configuration:

      config :http_client,
        timeout:          5_000,
        retry_count:      3,
        retry_delay_ms:   500,
        follow_redirects: true,
        base_headers:     [{"content-type", "application/json"}]
  """

  require Logger

  @type method   :: :get | :post | :put | :patch | :delete | :head
  @type headers  :: [{String.t(), String.t()}]
  @type response :: {:ok, %{status: integer(), body: String.t(), headers: headers()}}
                  | {:error, term()}

  @doc """
  Makes an HTTP GET request to the given URL.
  """
  def get(url, headers \\ []) do
    request(:get, url, %{headers: headers, body: ""})
  end

  @doc """
  Makes an HTTP POST request with a JSON-encoded body.
  """
  def post(url, body, headers \\ []) do
    request(:post, url, %{headers: headers, body: Jason.encode!(body)})
  end

  @doc """
  Makes an HTTP PUT request with a JSON-encoded body.
  """
  def put(url, body, headers \\ []) do
    request(:put, url, %{headers: headers, body: Jason.encode!(body)})
  end

  @doc """
  Makes an HTTP DELETE request to the given URL.
  """
  def delete(url, headers \\ []) do
    request(:delete, url, %{headers: headers, body: ""})
  end

  @doc """
  Core request function. All public request functions delegate here.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because timeout, retry_count, retry_delay_ms,
  # and follow_redirects are read from Application.fetch_env!/2 rather than
  # accepted as options, so every HTTP call in a dependent application must
  # use the same global settings regardless of the call's latency requirements.
  def request(method, url, opts \\ %{}) do
    timeout          = Application.fetch_env!(:http_client, :timeout)
    retry_count      = Application.fetch_env!(:http_client, :retry_count)
    retry_delay_ms   = Application.fetch_env!(:http_client, :retry_delay_ms)
    follow_redirects = Application.fetch_env!(:http_client, :follow_redirects)
    base_headers     = Application.fetch_env!(:http_client, :base_headers)
  # VALIDATION: SMELL END

    headers = base_headers ++ Map.get(opts, :headers, [])
    body    = Map.get(opts, :body, "")

    do_request(method, url, headers, body, %{
      timeout:          timeout,
      retry_count:      retry_count,
      retry_delay_ms:   retry_delay_ms,
      follow_redirects: follow_redirects,
      attempt:          1
    })
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_request(method, url, headers, body, %{attempt: attempt} = cfg) do
    Logger.debug("HTTP #{method |> to_string() |> String.upcase()} #{url} (attempt #{attempt})")

    start_ms = System.monotonic_time(:millisecond)

    result = simulate_http_call(method, url, headers, body, cfg.timeout)

    elapsed = System.monotonic_time(:millisecond) - start_ms
    Logger.debug("HTTP response in #{elapsed}ms")

    case result do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] ->
        if cfg.follow_redirects do
          location = get_header(resp.headers, "location")
          do_request(method, location, headers, body, cfg)
        else
          {:ok, resp}
        end

      {:ok, %{status: status}} when status in 500..599 and attempt < cfg.retry_count ->
        Logger.warning("HTTP #{status} on attempt #{attempt}, retrying...")
        Process.sleep(cfg.retry_delay_ms * attempt)
        do_request(method, url, headers, body, %{cfg | attempt: attempt + 1})

      {:ok, resp} ->
        {:ok, resp}

      {:error, :timeout} when attempt < cfg.retry_count ->
        Logger.warning("HTTP timeout on attempt #{attempt}, retrying...")
        Process.sleep(cfg.retry_delay_ms * attempt)
        do_request(method, url, headers, body, %{cfg | attempt: attempt + 1})

      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp simulate_http_call(_method, _url, _headers, _body, _timeout) do
    {:ok, %{status: 200, body: "{}", headers: [{"content-type", "application/json"}]}}
  end

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil        -> nil
    end
  end
end
```
