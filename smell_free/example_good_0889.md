```elixir
defmodule Http.Client do
  @moduledoc """
  A declarative HTTP client that composes a configurable middleware stack
  around Req. Middleware modules intercept requests and responses to add
  authentication, logging, metrics, and retry logic without coupling those
  concerns to call sites. Each middleware is a module implementing the
  `Http.Middleware` behaviour, making the stack testable in isolation.
  """

  alias Http.{Middleware, Request, Response}

  @type client_opts :: [
          base_url: binary(),
          timeout_ms: pos_integer(),
          middleware: [module()],
          default_headers: [{binary(), binary()}]
        ]

  @type request_opts :: [
          headers: [{binary(), binary()}],
          params: map(),
          body: term(),
          timeout_ms: pos_integer()
        ]

  @default_middleware [
    Http.Middleware.Logger,
    Http.Middleware.Metrics,
    Http.Middleware.Retry
  ]

  @doc """
  Creates a new client configuration. Returns a map used as the first
  argument to `get/3`, `post/3`, etc.
  """
  @spec new(client_opts()) :: map()
  def new(opts \\ []) do
    %{
      base_url: Keyword.get(opts, :base_url, ""),
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      middleware: Keyword.get(opts, :middleware, @default_middleware),
      default_headers: Keyword.get(opts, :default_headers, [])
    }
  end

  @doc "Performs a GET request."
  @spec get(map(), binary(), request_opts()) :: {:ok, Response.t()} | {:error, term()}
  def get(client, path, opts \\ []) do
    request(client, :get, path, opts)
  end

  @doc "Performs a POST request."
  @spec post(map(), binary(), request_opts()) :: {:ok, Response.t()} | {:error, term()}
  def post(client, path, opts \\ []) do
    request(client, :post, path, opts)
  end

  @doc "Performs a PUT request."
  @spec put(map(), binary(), request_opts()) :: {:ok, Response.t()} | {:error, term()}
  def put(client, path, opts \\ []) do
    request(client, :put, path, opts)
  end

  @doc "Performs a DELETE request."
  @spec delete(map(), binary(), request_opts()) :: {:ok, Response.t()} | {:error, term()}
  def delete(client, path, opts \\ []) do
    request(client, :delete, path, opts)
  end

  # ---------------------------------------------------------------------------
  # Core request execution
  # ---------------------------------------------------------------------------

  defp request(client, method, path, opts) do
    req = build_request(client, method, path, opts)
    pipeline = Middleware.build(client.middleware, &execute_request/1)
    pipeline.(req)
  end

  defp build_request(client, method, path, opts) do
    %Request{
      method: method,
      url: client.base_url <> path,
      headers: client.default_headers ++ Keyword.get(opts, :headers, []),
      params: Keyword.get(opts, :params, %{}),
      body: Keyword.get(opts, :body),
      timeout_ms: Keyword.get(opts, :timeout_ms, client.timeout_ms)
    }
  end

  defp execute_request(%Request{} = req) do
    req_opts = [
      method: req.method,
      url: req.url,
      headers: req.headers,
      params: req.params,
      receive_timeout: req.timeout_ms
    ]

    req_opts = if req.body, do: Keyword.put(req_opts, :body, encode_body(req.body)), else: req_opts

    case apply(Req, req.method, [req_opts]) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, %Response{status: status, body: body, headers: headers}}

      {:error, exception} ->
        {:error, {:transport_error, exception}}
    end
  end

  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: to_string(body)
end

defmodule Http.Middleware do
  @moduledoc "Behaviour and pipeline builder for HTTP middleware."

  @callback call(Http.Request.t(), next :: (Http.Request.t() -> {:ok, Http.Response.t()} | {:error, term()})) ::
              {:ok, Http.Response.t()} | {:error, term()}

  @spec build([module()], (Http.Request.t() -> {:ok, Http.Response.t()} | {:error, term()})) ::
          (Http.Request.t() -> {:ok, Http.Response.t()} | {:error, term()})
  def build(middlewares, terminal) do
    Enum.reduce_right(middlewares, terminal, fn mod, next ->
      fn req -> mod.call(req, next) end
    end)
  end
end

defmodule Http.Middleware.Retry do
  @moduledoc "Retries transient HTTP failures with exponential back-off."

  @behaviour Http.Middleware

  @max_attempts 3
  @base_delay_ms 200
  @retryable_statuses [429, 500, 502, 503, 504]

  @impl Http.Middleware
  def call(req, next), do: attempt(req, next, 1)

  defp attempt(req, next, n) do
    case next.(req) do
      {:ok, %{status: status}} = result when status in @retryable_statuses and n < @max_attempts ->
        Process.sleep(trunc(@base_delay_ms * :math.pow(2, n - 1)))
        attempt(req, next, n + 1)

      {:error, {:transport_error, _}} when n < @max_attempts ->
        Process.sleep(trunc(@base_delay_ms * :math.pow(2, n - 1)))
        attempt(req, next, n + 1)

      result ->
        result
    end
  end
end

defmodule Http.Request do
  @moduledoc false
  defstruct [:method, :url, :headers, :params, :body, :timeout_ms]
end

defmodule Http.Response do
  @moduledoc false
  defstruct [:status, :body, :headers]
end
```
