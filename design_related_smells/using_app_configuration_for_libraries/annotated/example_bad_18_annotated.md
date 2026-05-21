# Annotated Example 18

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `HTTPClient.request/3`
- **Affected function(s):** `request/3`
- **Short explanation:** `HTTPClient.request/3` retrieves `:timeout_ms`, `:max_retries`, and `:base_url` from the application environment rather than accepting them as keyword options. This prevents the library from being used with different timeout or retry policies at different call sites (e.g., a fast health-check endpoint vs. a slow data-export endpoint) within the same application.

## Code

```elixir
defmodule HTTPClient do
  @moduledoc """
  A thin HTTP client library built on top of `:httpc`. Provides automatic
  retries with exponential back-off, structured response parsing, and
  consistent error normalisation.

  Configuration in `config/config.exs`:

      config :http_client,
        base_url: "https://api.example.com",
        timeout_ms: 5_000,
        max_retries: 3
  """

  require Logger

  @doc """
  Issues an HTTP request to the given path relative to the configured base URL.

  `method` must be one of `:get`, `:post`, `:put`, `:patch`, `:delete`.

  `body` should be a binary or `nil` for methods without a request body.

  Returns `{:ok, %{status: integer, headers: list, body: binary}}` on success
  or `{:error, reason}` after exhausting retries.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because timeout_ms, max_retries, and base_url are
  # fetched from the Application Environment instead of being optional keyword parameters.
  # A caller needing a 30-second timeout for a bulk export endpoint and a 500ms timeout
  # for a health check cannot configure them independently without altering global config.
  def request(method, path, opts \\ []) do
    base_url = Application.fetch_env!(:http_client, :base_url)
    timeout_ms = Application.fetch_env!(:http_client, :timeout_ms)
    max_retries = Application.get_env(:http_client, :max_retries, 3)

    url = base_url <> path
    headers = build_headers(opts)
    body = Keyword.get(opts, :body, "")

    do_request(method, url, headers, body, timeout_ms, max_retries, 0)
  end
  # VALIDATION: SMELL END

  @doc """
  Convenience wrapper for GET requests.
  """
  def get(path, opts \\ []), do: request(:get, path, opts)

  @doc """
  Convenience wrapper for POST requests with a JSON body.
  """
  def post(path, body, opts \\ []) when is_map(body) do
    encoded = Jason.encode!(body)

    opts
    |> Keyword.put(:body, encoded)
    |> Keyword.put_new(:content_type, "application/json")
    |> then(&request(:post, path, &1))
  end

  @doc """
  Convenience wrapper for PUT requests with a JSON body.
  """
  def put(path, body, opts \\ []) when is_map(body) do
    encoded = Jason.encode!(body)

    opts
    |> Keyword.put(:body, encoded)
    |> Keyword.put_new(:content_type, "application/json")
    |> then(&request(:put, path, &1))
  end

  @doc """
  Decodes a JSON response body. Returns `{:ok, decoded}` or `{:error, reason}`.
  """
  def decode_json({:ok, %{body: body}}), do: Jason.decode(body)
  def decode_json({:error, _} = error), do: error

  ## Private helpers

  defp do_request(_method, _url, _headers, _body, _timeout, max_retries, attempt)
       when attempt > max_retries do
    {:error, :max_retries_exceeded}
  end

  defp do_request(method, url, headers, body, timeout, max_retries, attempt) do
    charlist_url = String.to_charlist(url)
    charlist_headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request_spec =
      case body do
        "" -> {charlist_url, charlist_headers}
        b -> {charlist_url, charlist_headers, ~c"application/json", b}
      end

    options = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(method, request_spec, options, []) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        {:ok, %{status: status, headers: resp_headers, body: to_string(resp_body)}}

      {:error, reason} ->
        back_off = trunc(:math.pow(2, attempt) * 200)
        Logger.warning("HTTP request failed (attempt #{attempt + 1}): #{inspect(reason)}, retrying in #{back_off}ms")
        Process.sleep(back_off)
        do_request(method, url, headers, body, timeout, max_retries, attempt + 1)
    end
  end

  defp build_headers(opts) do
    base = [{"Accept", "application/json"}, {"User-Agent", "HTTPClient/1.0"}]

    extra =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    base ++ extra
  end
end
```
