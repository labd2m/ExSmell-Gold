```elixir
defmodule Http.InstrumentedClient do
  @moduledoc """
  A thin wrapper around Finch that emits `:telemetry` events for every
  outbound HTTP request, capturing latency, status codes, and error
  reasons for observability pipelines.
  """

  @type request_opts :: [
          method: :get | :post | :put | :patch | :delete,
          headers: [{String.t(), String.t()}],
          body: iodata() | nil,
          receive_timeout: pos_integer()
        ]

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @type http_result :: {:ok, response()} | {:error, atom()}

  @default_timeout_ms 10_000

  @spec request(String.t(), request_opts()) :: http_result()
  def request(url, opts \\ []) when is_binary(url) do
    method = Keyword.get(opts, :method, :get)
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout_ms)

    start_time = System.monotonic_time()
    start_metadata = %{url: url, method: method}

    :telemetry.execute([:http_client, :request, :start], %{system_time: System.system_time()}, start_metadata)

    result = dispatch(method, url, headers, body, timeout)

    duration = System.monotonic_time() - start_time
    emit_stop_event(result, start_metadata, duration)

    result
  end

  @spec get(String.t(), request_opts()) :: http_result()
  def get(url, opts \\ []), do: request(url, Keyword.put(opts, :method, :get))

  @spec post(String.t(), iodata(), request_opts()) :: http_result()
  def post(url, body, opts \\ []) do
    request(url, opts |> Keyword.put(:method, :post) |> Keyword.put(:body, body))
  end

  @spec put(String.t(), iodata(), request_opts()) :: http_result()
  def put(url, body, opts \\ []) do
    request(url, opts |> Keyword.put(:method, :put) |> Keyword.put(:body, body))
  end

  @spec delete(String.t(), request_opts()) :: http_result()
  def delete(url, opts \\ []), do: request(url, Keyword.put(opts, :method, :delete))

  @spec dispatch(atom(), String.t(), list(), iodata() | nil, pos_integer()) :: http_result()
  defp dispatch(method, url, headers, body, timeout) do
    finch_request = Finch.build(method, url, headers, body)

    case Finch.request(finch_request, Http.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: resp_headers, body: resp_body}}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, %Mint.HTTPError{reason: reason}} ->
        {:error, reason}
    end
  end

  @spec emit_stop_event(http_result(), map(), integer()) :: :ok
  defp emit_stop_event({:ok, %{status: status}}, metadata, duration) do
    measurements = %{duration: duration}
    stop_meta = Map.merge(metadata, %{status: status, error: nil})
    :telemetry.execute([:http_client, :request, :stop], measurements, stop_meta)
    :ok
  end

  defp emit_stop_event({:error, reason}, metadata, duration) do
    measurements = %{duration: duration}
    stop_meta = Map.merge(metadata, %{status: nil, error: reason})
    :telemetry.execute([:http_client, :request, :stop], measurements, stop_meta)
    :ok
  end
end
```
