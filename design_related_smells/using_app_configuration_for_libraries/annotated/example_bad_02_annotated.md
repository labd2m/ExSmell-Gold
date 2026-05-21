# Annotated Example 02

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `HttpRetry.request/2`
- **Affected functions:** `request/2`
- **Short explanation:** The library fetches `:max_attempts` and `:backoff_ms` from `Application.get_env/3` instead of accepting them as options in the function call. This prevents different callers from specifying different retry strategies for different endpoints within the same application.

```elixir
defmodule HttpRetry do
  @moduledoc """
  A resilient HTTP client library that wraps Tesla or HTTPoison calls
  with configurable retry logic. Intended for use in service integrations
  where transient failures are expected.
  """

  require Logger

  @default_max_attempts 3
  @default_backoff_ms 500
  @retryable_statuses [429, 500, 502, 503, 504]

  defmodule Response do
    defstruct [:status, :body, :headers, :attempts]
  end

  defmodule RequestError do
    defexception [:message, :status, :attempts]
  end

  @doc """
  Executes an HTTP request with automatic retry on transient failures.

  `method` is an atom like `:get`, `:post`, `:put`, `:delete`.
  `request_opts` is a keyword list with `:url`, `:headers`, `:body`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because max_attempts and backoff_ms are read
  # from the Application Environment globally. A caller needing aggressive
  # retries for a payment endpoint and zero retries for an idempotency-check
  # endpoint cannot express that without changing the global config, since
  # these values are not accepted as function parameters.
  def request(method, request_opts) when is_atom(method) and is_list(request_opts) do
    max_attempts = Application.get_env(:http_retry, :max_attempts, @default_max_attempts)
    backoff_ms = Application.get_env(:http_retry, :backoff_ms, @default_backoff_ms)

    url = Keyword.fetch!(request_opts, :url)
    headers = Keyword.get(request_opts, :headers, [])
    body = Keyword.get(request_opts, :body, "")

    do_request(method, url, headers, body, max_attempts, backoff_ms, 1)
  end
  # VALIDATION: SMELL END

  @doc """
  Convenience wrapper for GET requests.
  """
  def get(url, headers \\ []) do
    request(:get, url: url, headers: headers)
  end

  @doc """
  Convenience wrapper for POST requests.
  """
  def post(url, body, headers \\ []) do
    request(:post, url: url, headers: headers, body: body)
  end

  # --- Private implementation ---

  defp do_request(method, url, headers, body, max_attempts, backoff_ms, attempt) do
    Logger.debug("HttpRetry: attempt #{attempt}/#{max_attempts} [#{method}] #{url}")

    case perform_http(method, url, headers, body) do
      {:ok, %{status: status} = resp} when status in @retryable_statuses ->
        if attempt < max_attempts do
          sleep_ms = backoff_ms * attempt
          Logger.warning("HttpRetry: retryable status #{status}, sleeping #{sleep_ms}ms")
          Process.sleep(sleep_ms)
          do_request(method, url, headers, body, max_attempts, backoff_ms, attempt + 1)
        else
          Logger.error("HttpRetry: exhausted #{max_attempts} attempts for #{url}")
          {:error, %RequestError{message: "Max attempts reached", status: status, attempts: attempt}}
        end

      {:ok, resp} ->
        {:ok, %Response{status: resp.status, body: resp.body, headers: resp.headers, attempts: attempt}}

      {:error, reason} ->
        if attempt < max_attempts do
          sleep_ms = backoff_ms * attempt
          Logger.warning("HttpRetry: connection error #{inspect(reason)}, retrying in #{sleep_ms}ms")
          Process.sleep(sleep_ms)
          do_request(method, url, headers, body, max_attempts, backoff_ms, attempt + 1)
        else
          {:error, %RequestError{message: inspect(reason), status: nil, attempts: attempt}}
        end
    end
  end

  defp perform_http(:get, url, headers, _body) do
    :httpc.request(:get, {String.to_charlist(url), headers}, [], [])
    |> parse_httpc_response()
  end

  defp perform_http(method, url, headers, body) when method in [:post, :put, :patch] do
    content_type = 'application/json'
    :httpc.request(method, {String.to_charlist(url), headers, content_type, body}, [], [])
    |> parse_httpc_response()
  end

  defp parse_httpc_response({:ok, {{_, status, _}, headers, body}}) do
    {:ok, %{status: status, headers: headers, body: to_string(body)}}
  end

  defp parse_httpc_response({:error, reason}), do: {:error, reason}
end
```
