# Annotated Bad Example 15

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@http_timeout_ms` defined at the top of `Integrations.ExternalApiClient`
- **Affected function(s):** `get/2`, `post/3`, `delete/2`
- **Short explanation:** `Application.fetch_env!/2` is used in the module body to read the HTTP timeout from the Application Environment and store it as a module attribute. This happens at compile-time when the `:integrations` application configuration may not be available, potentially producing a compilation warning or `ArgumentError`.

---

```elixir
defmodule Integrations.ExternalApiClient do
  @moduledoc """
  Generic HTTP client for outbound integrations. Handles request signing,
  retry logic with exponential back-off, and structured error normalisation.
  Used by higher-level integration adapters (CRM, ERP, analytics, etc.).
  """

  require Logger

  @max_retries 3
  @backoff_base_ms 200

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called in the
  # VALIDATION: module body, assigning the timeout to a module attribute. Module
  # VALIDATION: attributes are resolved during compilation; the :integrations
  # VALIDATION: application may not have its environment loaded at that point,
  # VALIDATION: causing a warning or ArgumentError to be raised at compile-time.
  @http_timeout_ms Application.fetch_env!(:integrations, :http_timeout_ms)
  # VALIDATION: SMELL END

  @type method :: :get | :post | :put | :patch | :delete
  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, map() | [map()] | String.t()} | {:error, map()}

  @doc """
  Performs a GET request to `url` with optional `query_params`.

  ## Parameters
    - `url` - Fully qualified URL.
    - `query_params` - Map of query-string parameters (default `%{}`).
  """
  @spec get(String.t(), map()) :: response()
  def get(url, query_params \\ %{}) do
    full_url =
      if map_size(query_params) > 0 do
        url <> "?" <> URI.encode_query(query_params)
      else
        url
      end

    execute(:get, full_url, nil, default_headers())
  end

  @doc """
  Performs a POST request to `url` with a JSON `body`.

  ## Parameters
    - `url` - Fully qualified URL.
    - `body` - Elixir term to be JSON-encoded as the request body.
    - `extra_headers` - Additional headers to merge with defaults.
  """
  @spec post(String.t(), term(), headers()) :: response()
  def post(url, body, extra_headers \\ []) do
    headers = default_headers() ++ extra_headers
    execute(:post, url, body, headers)
  end

  @doc """
  Performs a DELETE request to `url`.
  """
  @spec delete(String.t(), headers()) :: response()
  def delete(url, extra_headers \\ []) do
    headers = default_headers() ++ extra_headers
    execute(:delete, url, nil, headers)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp execute(method, url, body, headers, attempt \\ 1) do
    encoded_body = if body, do: Jason.encode!(body), else: ""

    result =
      case method do
        :get    -> HTTPoison.get(url, headers, recv_timeout: @http_timeout_ms)
        :post   -> HTTPoison.post(url, encoded_body, headers, recv_timeout: @http_timeout_ms)
        :put    -> HTTPoison.put(url, encoded_body, headers, recv_timeout: @http_timeout_ms)
        :patch  -> HTTPoison.patch(url, encoded_body, headers, recv_timeout: @http_timeout_ms)
        :delete -> HTTPoison.delete(url, headers, recv_timeout: @http_timeout_ms)
      end

    case result do
      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} when code in 200..299 ->
        parse_response(resp_body)

      {:ok, %HTTPoison.Response{status_code: 429}} when attempt <= @max_retries ->
        backoff = @backoff_base_ms * :math.pow(2, attempt - 1) |> round()
        Logger.warning("Rate limited, retrying in #{backoff}ms attempt=#{attempt}")
        Process.sleep(backoff)
        execute(method, url, body, headers, attempt + 1)

      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} ->
        error_body = parse_response(resp_body)
        Logger.error("HTTP #{code} from #{url}: #{inspect(error_body)}")
        {:error, %{status: code, body: error_body}}

      {:error, %HTTPoison.Error{reason: :timeout}} when attempt <= @max_retries ->
        backoff = @backoff_base_ms * :math.pow(2, attempt - 1) |> round()
        Logger.warning("Timeout, retrying in #{backoff}ms attempt=#{attempt}")
        Process.sleep(backoff)
        execute(method, url, body, headers, attempt + 1)

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP error url=#{url} reason=#{inspect(reason)}")
        {:error, %{status: nil, body: inspect(reason)}}
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
    end
  end

  defp default_headers do
    api_key = Application.get_env(:integrations, :api_key, "")
    [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"X-Api-Key", api_key}
    ]
  end
end
```
