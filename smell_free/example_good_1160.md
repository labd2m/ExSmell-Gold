```elixir
defmodule Integrations.HttpClient do
  @moduledoc """
  Thin HTTP client wrapper providing structured request and response handling
  for communication with external service APIs.

  All responses are normalized to `{:ok, response}` or `{:error, reason}`
  tuples. HTTP status failures are mapped to domain error atoms so callers
  remain decoupled from raw HTTP semantics. Logging is applied consistently
  on all non-success paths.
  """

  require Logger

  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type response :: %{status: pos_integer(), body: term(), headers: headers()}
  @type http_error ::
          :unauthorized
          | :forbidden
          | :not_found
          | :unprocessable_entity
          | :rate_limited
          | :server_error
          | :timeout
          | :network_error

  @default_timeout_ms 15_000

  @doc "Sends a GET request and returns a normalized response."
  @spec get(url(), headers(), keyword()) :: {:ok, response()} | {:error, http_error()}
  def get(url, headers \\ [], opts \\ []) when is_binary(url) do
    execute(:get, url, nil, headers, opts)
  end

  @doc "Sends a POST request with a JSON-encodable body."
  @spec post(url(), map(), headers(), keyword()) :: {:ok, response()} | {:error, http_error()}
  def post(url, body, headers \\ [], opts \\ []) when is_binary(url) and is_map(body) do
    execute(:post, url, body, headers, opts)
  end

  @doc "Sends a PATCH request with a JSON-encodable body."
  @spec patch(url(), map(), headers(), keyword()) :: {:ok, response()} | {:error, http_error()}
  def patch(url, body, headers \\ [], opts \\ []) when is_binary(url) and is_map(body) do
    execute(:patch, url, body, headers, opts)
  end

  @doc "Sends a DELETE request to the given URL."
  @spec delete(url(), headers(), keyword()) :: {:ok, response()} | {:error, http_error()}
  def delete(url, headers \\ [], opts \\ []) when is_binary(url) do
    execute(:delete, url, nil, headers, opts)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp execute(method, url, body, headers, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    req_opts =
      [method: method, url: url, headers: headers, receive_timeout: timeout]
      |> maybe_put_body(body)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        interpret_status(status, resp_body, resp_headers, url)

      {:error, %Req.TransportError{reason: :timeout}} ->
        log_failure(method, url, :timeout)
        {:error, :timeout}

      {:error, reason} ->
        log_failure(method, url, reason)
        {:error, :network_error}
    end
  end

  defp interpret_status(status, body, headers, _url) when status in 200..299 do
    {:ok, %{status: status, body: body, headers: headers}}
  end

  defp interpret_status(status, _body, _headers, url) do
    error = map_status_to_error(status)
    Logger.warning("HTTP non-success response", url: url, status: status, error: error)
    {:error, error}
  end

  defp map_status_to_error(401), do: :unauthorized
  defp map_status_to_error(403), do: :forbidden
  defp map_status_to_error(404), do: :not_found
  defp map_status_to_error(422), do: :unprocessable_entity
  defp map_status_to_error(429), do: :rate_limited
  defp map_status_to_error(status) when status in 500..599, do: :server_error
  defp map_status_to_error(_), do: :server_error

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)

  defp log_failure(method, url, reason) do
    Logger.error("HTTP request failed",
      method: method,
      url: url,
      reason: inspect(reason)
    )
  end
end
```
