```elixir
defmodule Network.RetryableHTTP do
  @moduledoc """
  Wraps HTTPoison with automatic retry logic using an exponential backoff
  strategy. Retries are attempted only for transient errors: network
  timeouts, connection failures, and 5xx responses. 4xx client errors
  are returned immediately without retrying. The module is stateless and
  safe to call from any process or context.
  """

  require Logger

  @type method :: :get | :post | :put | :patch | :delete
  @type response :: %{status: pos_integer(), body: String.t(), headers: list()}
  @type request_error :: :timeout | :connection_refused | :server_error | :client_error
  @type request_result :: {:ok, response()} | {:error, request_error()}

  @default_max_attempts 4
  @initial_backoff_ms 500
  @max_backoff_ms 16_000

  @doc """
  Performs an HTTP request with automatic retry on transient failures.
  Accepts `max_attempts` and `timeout_ms` in `opts`.
  """
  @spec request(method(), String.t(), map() | binary(), list(), keyword()) :: request_result()
  def request(method, url, body \ "", headers \ [], opts \ [])
      when is_atom(method) and is_binary(url) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    attempt_request(method, url, body, headers, timeout_ms, 1, max_attempts)
  end

  defp attempt_request(_method, _url, _body, _headers, _timeout, attempt, max) when attempt > max do
    {:error, :server_error}
  end

  defp attempt_request(method, url, body, headers, timeout, attempt, max) do
    raw_body = encode_body(body)

    result =
      apply(HTTPoison, method, [url, raw_body, headers, [recv_timeout: timeout]])

    case classify(result) do
      {:ok, response} ->
        {:ok, response}

      {:retry, reason} when attempt < max ->
        delay = compute_backoff(attempt)
        Logger.warning("[RetryableHTTP] #{method} #{url} failed (#{reason}), retry #{attempt}/#{max - 1} in #{delay}ms")
        Process.sleep(delay)
        attempt_request(method, url, body, headers, timeout, attempt + 1, max)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify({:ok, %{status_code: status, body: body, headers: headers}})
       when status in 200..299 do
    {:ok, %{status: status, body: body, headers: headers}}
  end

  defp classify({:ok, %{status_code: status}}) when status in 500..599 do
    {:retry, :server_error}
  end

  defp classify({:ok, %{status_code: status}}) when status in 400..499 do
    {:error, :client_error}
  end

  defp classify({:ok, _}), do: {:error, :server_error}

  defp classify({:error, %HTTPoison.Error{reason: :timeout}}), do: {:retry, :timeout}
  defp classify({:error, %HTTPoison.Error{reason: :connect_timeout}}), do: {:retry, :timeout}
  defp classify({:error, %HTTPoison.Error{reason: :econnrefused}}), do: {:retry, :connection_refused}
  defp classify({:error, _}), do: {:retry, :connection_refused}

  defp compute_backoff(attempt) do
    raw = @initial_backoff_ms * :math.pow(2, attempt - 1) |> trunc()
    jitter = :rand.uniform(div(raw, 4) + 1)
    min(raw + jitter, @max_backoff_ms)
  end

  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(_), do: ""
end
```
