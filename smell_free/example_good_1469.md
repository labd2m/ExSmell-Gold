```elixir
defmodule HttpClient.Config do
  @moduledoc """
  Runtime configuration for an HTTP client instance.
  Pass this struct when calling client functions to support concurrent
  multi-tenant configurations without global state coupling.
  """

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          max_retries: non_neg_integer(),
          initial_delay_ms: pos_integer(),
          timeout_ms: pos_integer()
        }

  defstruct [
    :base_url,
    :api_key,
    max_retries: 3,
    initial_delay_ms: 200,
    timeout_ms: 5_000
  ]
end

defmodule HttpClient do
  alias HttpClient.Config

  @moduledoc """
  A resilient HTTP client that retries transient failures with
  exponential backoff. Configuration is fully runtime-injectable.
  """

  @retryable_statuses [429, 500, 502, 503, 504]

  @type response :: %{status: integer(), body: map() | binary()}

  @spec get(Config.t(), String.t(), keyword()) ::
          {:ok, response()} | {:error, :max_retries_exceeded | term()}
  def get(%Config{} = config, path, params \\ []) when is_binary(path) do
    url = build_url(config.base_url, path, params)
    headers = auth_headers(config.api_key)
    execute_with_retry(config, :get, url, headers, nil, 0)
  end

  @spec post(Config.t(), String.t(), map()) ::
          {:ok, response()} | {:error, :max_retries_exceeded | term()}
  def post(%Config{} = config, path, body) when is_binary(path) and is_map(body) do
    url = build_url(config.base_url, path, [])
    headers = auth_headers(config.api_key) ++ [{"content-type", "application/json"}]
    execute_with_retry(config, :post, url, headers, Jason.encode!(body), 0)
  end

  defp execute_with_retry(config, method, url, headers, body, attempt) do
    req_opts = [headers: headers, receive_timeout: config.timeout_ms]
    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    result =
      case method do
        :get -> Req.get(url, req_opts)
        :post -> Req.post(url, req_opts)
      end

    handle_result(result, config, method, url, headers, body, attempt)
  end

  defp handle_result({:ok, %{status: status} = resp}, _config, _m, _u, _h, _b, _attempt)
       when status not in @retryable_statuses do
    {:ok, %{status: status, body: resp.body}}
  end

  defp handle_result({:ok, %{status: status}}, config, method, url, headers, body, attempt)
       when status in @retryable_statuses do
    retry_or_fail(config, method, url, headers, body, attempt, {:http_error, status})
  end

  defp handle_result({:error, reason}, config, method, url, headers, body, attempt) do
    retry_or_fail(config, method, url, headers, body, attempt, reason)
  end

  defp retry_or_fail(_config, _method, _url, _headers, _body, attempt, _reason)
       when attempt >= 3 do
    {:error, :max_retries_exceeded}
  end

  defp retry_or_fail(config, method, url, headers, body, attempt, _reason) do
    delay = config.initial_delay_ms * :math.pow(2, attempt) |> round()
    Process.sleep(delay)
    execute_with_retry(config, method, url, headers, body, attempt + 1)
  end

  defp build_url(base, path, []), do: "#{base}#{path}"

  defp build_url(base, path, params) do
    query = URI.encode_query(params)
    "#{base}#{path}?#{query}"
  end

  defp auth_headers(api_key), do: [{"authorization", "Bearer #{api_key}"}]
end
```
