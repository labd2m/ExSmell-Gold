```elixir
defmodule ApiGateway.Client do
  @moduledoc """
  HTTP client for the internal micro-service gateway. All outbound requests
  are authenticated with HMAC-SHA256 request signing.
  """

  alias ApiGateway.{Config, HttpAdapter, Response}

  @signing_algorithm :sha256
  @timestamp_header  "X-Request-Timestamp"
  @signature_header  "X-Request-Signature"
  @key_id_header     "X-Key-Id"


  @doc """
  Performs a signed GET request to the gateway path.
  Returns `{:ok, Response.t()}` or `{:error, reason}`.
  """
  def get(path, query_params \\ %{}) do
    config    = Config.load!()
    timestamp = :os.system_time(:second) |> to_string()

    encoded_query = URI.encode_query(query_params)
    full_path     = if encoded_query == "", do: path, else: "#{path}?#{encoded_query}"
    url           = "#{config.base_url}#{full_path}"

    canonical_string = Enum.join(["GET", full_path, timestamp], "\n")

    signature =
      :crypto.mac(:hmac, @signing_algorithm, config.secret_key, canonical_string)
      |> Base.encode16(case: :lower)

    auth_headers = [
      {@timestamp_header,  timestamp},
      {@signature_header,  signature},
      {@key_id_header,     config.key_id},
      {"Content-Type",     "application/json"},
      {"Accept",           "application/json"}
    ]

    case HttpAdapter.get(url, auth_headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %Response{status: status, body: Jason.decode!(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Jason.decode!(body)}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end


  @doc """
  Performs a signed POST request to the gateway path with a JSON body.
  Returns `{:ok, Response.t()}` or `{:error, reason}`.
  """
  def post(path, payload, opts \\ []) do
    config    = Config.load!()
    timestamp = :os.system_time(:second) |> to_string()
    body      = Jason.encode!(payload)
    url       = "#{config.base_url}#{path}"

    canonical_string = Enum.join(["POST", path, timestamp], "\n")

    signature =
      :crypto.mac(:hmac, @signing_algorithm, config.secret_key, canonical_string)
      |> Base.encode16(case: :lower)

    auth_headers = [
      {@timestamp_header,  timestamp},
      {@signature_header,  signature},
      {@key_id_header,     config.key_id},
      {"Content-Type",     "application/json"},
      {"Accept",           "application/json"}
    ]

    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    case HttpAdapter.post(url, body, auth_headers, recv_timeout: timeout) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, %Response{status: status, body: Jason.decode!(resp_body)}}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http_error, status, Jason.decode!(resp_body)}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end
end
```
