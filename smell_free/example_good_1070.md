**File:** `example_good_1070.md`

```elixir
defmodule HttpClient do
  @moduledoc """
  Resilient HTTP client wrapper with configurable retry logic and
  circuit breaker integration. All responses are normalized to tagged
  tuples regardless of the underlying transport outcome.
  """

  alias HttpClient.{CircuitBreaker, RetryPolicy, ResponseParser}

  @type request :: %{
          method: :get | :post | :put | :patch | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata() | nil
        }

  @type response :: %{status: integer(), headers: map(), body: binary()}

  @type request_opts :: [
          timeout_ms: pos_integer(),
          retries: non_neg_integer(),
          retry_on: [integer()],
          circuit_breaker: atom() | nil
        ]

  @spec request(request(), request_opts()) :: {:ok, response()} | {:error, term()}
  def request(%{method: method, url: url} = req, opts \\ []) when is_atom(method) and is_binary(url) do
    circuit = Keyword.get(opts, :circuit_breaker)

    if circuit && CircuitBreaker.open?(circuit) do
      {:error, :circuit_open}
    else
      result = execute_with_retries(req, opts)
      maybe_report_to_circuit(circuit, result)
      result
    end
  end

  @spec get(String.t(), request_opts()) :: {:ok, response()} | {:error, term()}
  def get(url, opts \\ []) when is_binary(url) do
    request(%{method: :get, url: url, headers: [], body: nil}, opts)
  end

  @spec post(String.t(), iodata(), request_opts()) :: {:ok, response()} | {:error, term()}
  def post(url, body, opts \\ []) when is_binary(url) do
    request(%{method: :post, url: url, headers: default_json_headers(), body: body}, opts)
  end

  defp execute_with_retries(req, opts) do
    max_retries = Keyword.get(opts, :retries, 2)
    retry_statuses = Keyword.get(opts, :retry_on, [429, 500, 502, 503, 504])
    timeout = Keyword.get(opts, :timeout_ms, 10_000)

    execute_attempt(req, timeout, retry_statuses, max_retries, 0)
  end

  defp execute_attempt(req, timeout, retry_statuses, max_retries, attempt) do
    case send_request(req, timeout) do
      {:ok, %{status: status} = response} when status in retry_statuses and attempt < max_retries ->
        backoff = RetryPolicy.backoff_ms(attempt)
        Process.sleep(backoff)
        execute_attempt(req, timeout, retry_statuses, max_retries, attempt + 1)

      {:ok, response} ->
        {:ok, ResponseParser.parse(response)}

      {:error, _reason} when attempt < max_retries ->
        backoff = RetryPolicy.backoff_ms(attempt)
        Process.sleep(backoff)
        execute_attempt(req, timeout, retry_statuses, max_retries, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_request(%{method: method, url: url, headers: headers, body: body}, timeout) do
    :hackney.request(method, url, headers, body || "", recv_timeout: timeout)
    |> normalize_hackney_response()
  end

  defp normalize_hackney_response({:ok, status, headers, ref}) do
    case :hackney.body(ref) do
      {:ok, body} ->
        {:ok, %{status: status, headers: Map.new(headers), body: body}}

      {:error, reason} ->
        {:error, {:body_read_error, reason}}
    end
  end

  defp normalize_hackney_response({:error, reason}), do: {:error, reason}

  defp maybe_report_to_circuit(nil, _result), do: :ok
  defp maybe_report_to_circuit(circuit, {:ok, _}), do: CircuitBreaker.record_success(circuit)
  defp maybe_report_to_circuit(circuit, {:error, _}), do: CircuitBreaker.record_failure(circuit)

  defp default_json_headers do
    [{"content-type", "application/json"}, {"accept", "application/json"}]
  end
end

defmodule HttpClient.RetryPolicy do
  @moduledoc "Exponential backoff with jitter for HTTP retries."

  @base_ms 200
  @max_ms 5_000

  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    jitter = :rand.uniform(100)
    calculated = @base_ms * Integer.pow(2, attempt) + jitter
    min(calculated, @max_ms)
  end
end
```
