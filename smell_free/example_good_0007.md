# File: `example_good_07.md`

```elixir
defmodule HTTP.RetryClient do
  @moduledoc """
  HTTP client wrapper with configurable retry logic using exponential
  backoff. Each request is described by an `HTTP.RetryClient.Request`
  struct so that callers do not need to maintain positional argument lists.

  All public functions return tagged tuples; no exceptions are raised for
  normal network or protocol-level failures.
  """

  require Logger

  @type method :: :get | :post | :put | :patch | :delete
  @type headers :: [{String.t(), String.t()}]
  @type body :: String.t() | nil

  @type request :: %{
          required(:method) => method(),
          required(:url) => String.t(),
          optional(:headers) => headers(),
          optional(:body) => body(),
          optional(:timeout_ms) => pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: headers(),
          body: String.t()
        }

  @type retry_opts :: [
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          retryable_statuses: [non_neg_integer()]
        ]

  @default_max_attempts 3
  @default_base_delay_ms 200
  @default_retryable_statuses [429, 500, 502, 503, 504]
  @default_timeout_ms 5_000

  @doc """
  Issues an HTTP request with automatic retry on transient failures.

  Options:
  - `:max_attempts` — total attempts before giving up (default: 3)
  - `:base_delay_ms` — initial backoff delay in milliseconds (default: 200)
  - `:retryable_statuses` — HTTP status codes that trigger a retry

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec request(request(), retry_opts()) ::
          {:ok, response()} | {:error, atom() | String.t()}
  def request(%{method: method, url: url} = req, opts \\ [])
      when is_atom(method) and is_binary(url) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    retryable = Keyword.get(opts, :retryable_statuses, @default_retryable_statuses)

    attempt(req, 1, max_attempts, base_delay_ms, retryable)
  end

  defp attempt(req, attempt_number, max_attempts, base_delay_ms, retryable) do
    case execute(req) do
      {:ok, %{status: status} = response} when status in retryable ->
        retry_or_fail(req, attempt_number, max_attempts, base_delay_ms, retryable, status)

      {:ok, response} ->
        {:ok, response}

      {:error, _reason} = error when attempt_number >= max_attempts ->
        error

      {:error, reason} ->
        Logger.warning("HTTP request failed (attempt #{attempt_number}): #{inspect(reason)}")
        sleep_with_backoff(attempt_number, base_delay_ms)
        attempt(req, attempt_number + 1, max_attempts, base_delay_ms, retryable)
    end
  end

  defp retry_or_fail(req, attempt_number, max_attempts, base_delay_ms, retryable, status) do
    if attempt_number >= max_attempts do
      {:error, {:retryable_status_exhausted, status}}
    else
      Logger.warning("Retryable HTTP status #{status} on attempt #{attempt_number}")
      sleep_with_backoff(attempt_number, base_delay_ms)
      attempt(req, attempt_number + 1, max_attempts, base_delay_ms, retryable)
    end
  end

  defp execute(%{method: method, url: url} = req) do
    headers = Map.get(req, :headers, [])
    body = Map.get(req, :body, "")
    timeout = Map.get(req, :timeout_ms, @default_timeout_ms)

    case :httpc.request(
           method,
           {String.to_charlist(url), to_charlist_headers(headers), ~c"application/json",
            body || ~c""},
           [{:timeout, timeout}],
           []
         ) do
      {:ok, {{_http, status, _reason}, resp_headers, resp_body}} ->
        {:ok,
         %{
           status: status,
           headers: parse_response_headers(resp_headers),
           body: IO.iodata_to_binary(resp_body)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sleep_with_backoff(attempt_number, base_delay_ms) do
    delay = base_delay_ms * Integer.pow(2, attempt_number - 1)
    jitter = :rand.uniform(div(delay, 4))
    Process.sleep(delay + jitter)
  end

  defp to_charlist_headers(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  defp parse_response_headers(headers) do
    Enum.map(headers, fn {k, v} ->
      {List.to_string(k), List.to_string(v)}
    end)
  end
end
```
