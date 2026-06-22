```elixir
defmodule Platform.RegionalClient do
  @moduledoc """
  An HTTP client that routes requests to a primary regional endpoint
  and automatically retries against failover endpoints when the primary
  is unavailable.

  Endpoints are tried in priority order. A request is considered failed
  if it returns a 5xx status, times out, or raises a connection error.
  Successful responses from failover endpoints are returned normally.
  """

  @type endpoint :: %{url: String.t(), priority: pos_integer(), region: String.t()}
  @type response :: %{status: pos_integer(), body: map(), region: String.t()}
  @type result :: {:ok, response()} | {:error, :all_endpoints_failed}

  @default_timeout_ms 8_000

  @doc """
  Executes a GET request across available `endpoints` in priority order,
  stopping at the first successful response.
  """
  @spec get(String.t(), [endpoint()], keyword()) :: result()
  def get(path, endpoints, opts \\ []) when is_binary(path) and is_list(endpoints) do
    request(:get, path, nil, endpoints, opts)
  end

  @doc """
  Executes a POST request with `body` across available `endpoints`.
  """
  @spec post(String.t(), map(), [endpoint()], keyword()) :: result()
  def post(path, body, endpoints, opts \\ []) when is_binary(path) and is_map(body) do
    request(:post, path, body, endpoints, opts)
  end

  defp request(method, path, body, endpoints, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    headers = build_headers(opts)

    endpoints
    |> Enum.sort_by(& &1.priority)
    |> Enum.reduce_while({:error, :all_endpoints_failed}, fn endpoint, _acc ->
      url = endpoint.url <> path

      case attempt_request(method, url, body, headers, timeout) do
        {:ok, response} ->
          {:halt, {:ok, Map.put(response, :region, endpoint.region)}}

        {:error, reason} ->
          require Logger
          Logger.warning("[RegionalClient] Endpoint failed, trying next",
            region: endpoint.region,
            url: url,
            reason: inspect(reason)
          )
          {:cont, {:error, :all_endpoints_failed}}
      end
    end)
  end

  defp attempt_request(method, url, body, headers, timeout) do
    encoded_body = if body, do: Jason.encode!(body), else: ""

    case Req.request(method: method, url: url, body: encoded_body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, %{status: status, body: decode_body(resp_body)}}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, {:server_error, status}}

      {:ok, %{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: decode_body(resp_body)}}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  defp build_headers(opts) do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]
    extra = Keyword.get(opts, :headers, [])
    base ++ extra
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{raw: body}
    end
  end

  defp decode_body(body) when is_map(body), do: body
  defp decode_body(_body), do: %{}
end
```
