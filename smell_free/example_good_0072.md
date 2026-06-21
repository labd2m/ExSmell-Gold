```elixir
defmodule HttpGateway.Response do
  @moduledoc false

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          raw_body: binary()
        }

  defstruct [:status, :headers, :raw_body]

  @spec new(non_neg_integer(), list(), binary()) :: t()
  def new(status, headers, body) do
    %__MODULE__{status: status, headers: headers, raw_body: body}
  end

  @spec json_body(t()) :: {:ok, term()} | {:error, :invalid_json}
  def json_body(%__MODULE__{raw_body: body}) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end

defmodule HttpGateway.Client do
  @moduledoc """
  A typed HTTP client wrapping Finch with consistent error normalization.

  All responses are normalized to a tagged tuple, eliminating the need
  for callers to catch exceptions. Transport failures, timeouts, and
  non-success HTTP statuses are each mapped to distinct error shapes,
  giving call sites precise pattern-matching targets for recovery logic.
  """

  alias HttpGateway.Response

  @type request_error ::
          {:transport_error, term()}
          | :timeout
          | {:http_error, non_neg_integer(), binary()}

  @type result :: {:ok, Response.t()} | {:error, request_error()}

  @spec get(String.t(), keyword()) :: result()
  def get(url, opts \\ []) when is_binary(url) do
    execute(:get, url, nil, resolve_headers(opts), opts)
  end

  @spec post(String.t(), map(), keyword()) :: result()
  def post(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    headers = [{"content-type", "application/json"} | resolve_headers(opts)]
    execute(:post, url, Jason.encode!(body), headers, opts)
  end

  @spec put(String.t(), map(), keyword()) :: result()
  def put(url, body, opts \\ []) when is_binary(url) and is_map(body) do
    headers = [{"content-type", "application/json"} | resolve_headers(opts)]
    execute(:put, url, Jason.encode!(body), headers, opts)
  end

  @spec delete(String.t(), keyword()) :: result()
  def delete(url, opts \\ []) when is_binary(url) do
    execute(:delete, url, nil, resolve_headers(opts), opts)
  end

  defp execute(method, url, body, headers, opts) do
    request = Finch.build(method, url, headers, body)
    finch_name = Keyword.get(opts, :finch, HttpGateway.Finch)

    case Finch.request(request, finch_name) do
      {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}}
      when status in 200..299 ->
        {:ok, Response.new(status, resp_headers, resp_body)}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp resolve_headers(opts), do: Keyword.get(opts, :headers, [])
end
```
