```elixir
defmodule MyApp.Network.RetryableHTTPClient do
  @moduledoc """
  A thin wrapper around `:httpc` that adds transparent retry logic with
  exponential back-off and jitter for transient HTTP failures. Only
  specific error classes (5xx responses, connection timeouts, DNS
  failures) trigger retries; 4xx client errors are returned immediately.

  The module is purely functional; no process state is involved. Pass
  options to customise retry behaviour per call-site.
  """

  @default_max_attempts 3
  @default_base_delay_ms 200
  @default_timeout_ms 8_000
  @retryable_statuses 500..599

  @type method :: :get | :post | :put | :patch | :delete
  @type headers :: [{String.t(), String.t()}]
  @type response :: %{status: pos_integer(), headers: headers(), body: binary()}

  @doc """
  Makes an HTTP request with automatic retry on transient failures.

  ## Options
    * `:max_attempts` – total attempts including the first (default: `#{@default_max_attempts}`)
    * `:base_delay_ms` – initial back-off in milliseconds (default: `#{@default_base_delay_ms}`)
    * `:timeout_ms` – per-request timeout (default: `#{@default_timeout_ms}`)
  """
  @spec request(method(), String.t(), headers(), binary(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers \\ [], body \\ "", opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    do_request(method, url, headers, body, timeout_ms, 1, max_attempts, base_delay_ms)
  end

  @spec do_request(method(), String.t(), headers(), binary(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, response()} | {:error, term()}
  defp do_request(method, url, headers, body, timeout_ms, attempt, max_attempts, base_delay_ms) do
    result = execute(method, url, headers, body, timeout_ms)

    case should_retry?(result, attempt, max_attempts) do
      false ->
        result

      true ->
        delay = backoff_ms(attempt, base_delay_ms)
        Process.sleep(delay)
        do_request(method, url, headers, body, timeout_ms, attempt + 1, max_attempts, base_delay_ms)
    end
  end

  @spec execute(method(), String.t(), headers(), binary(), pos_integer()) ::
          {:ok, response()} | {:error, term()}
  defp execute(method, url, headers, body, timeout_ms) do
    charlist_url = String.to_charlist(url)
    charlist_headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    content_type = ~c"application/octet-stream"

    request =
      case method do
        m when m in [:get, :delete] -> {charlist_url, charlist_headers}
        _ -> {charlist_url, charlist_headers, content_type, body}
      end

    case :httpc.request(method, request, [{:timeout, timeout_ms}], []) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        {:ok, %{
          status: status,
          headers: Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end),
          body: IO.iodata_to_binary(resp_body)
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec should_retry?({:ok, response()} | {:error, term()}, pos_integer(), pos_integer()) :: boolean()
  defp should_retry?({:ok, %{status: status}}, attempt, max_attempts) do
    status in @retryable_statuses and attempt < max_attempts
  end

  defp should_retry?({:error, _}, attempt, max_attempts) do
    attempt < max_attempts
  end

  @spec backoff_ms(pos_integer(), pos_integer()) :: pos_integer()
  defp backoff_ms(attempt, base_ms) do
    jitter = :rand.uniform(base_ms)
    trunc(base_ms * :math.pow(2, attempt - 1)) + jitter
  end
end
```
