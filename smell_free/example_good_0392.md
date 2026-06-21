```elixir
defmodule MyAppWeb.Plug.ApiVersion do
  @moduledoc """
  Extracts and validates the requested API version from the
  `Accept` header (e.g., `application/vnd.myapp.v2+json`) or falls back
  to the `X-API-Version` header. Assigns `:api_version` on the connection
  so downstream controllers and views can render version-appropriate responses.
  Rejects requests that specify an unsupported version with `406 Not Acceptable`.
  """

  @behaviour Plug

  import Plug.Conn

  @supported_versions ~w[v1 v2 v3]
  @default_version "v3"
  @accept_pattern ~r/application\/vnd\.myapp\.(v\d+)\+json/

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case resolve_version(conn) do
      {:ok, version} ->
        assign(conn, :api_version, version)

      {:error, :unsupported_version} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:not_acceptable, Jason.encode!(%{
             error: "unsupported_api_version",
             supported: @supported_versions
           }))
        |> halt()
    end
  end

  defp resolve_version(conn) do
    version =
      extract_from_accept(conn) ||
        extract_from_header(conn) ||
        @default_version

    if version in @supported_versions do
      {:ok, version}
    else
      {:error, :unsupported_version}
    end
  end

  defp extract_from_accept(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.find_value(fn header ->
      case Regex.run(@accept_pattern, header) do
        [_, version] -> version
        _ -> nil
      end
    end)
  end

  defp extract_from_header(conn) do
    case get_req_header(conn, "x-api-version") do
      [version | _] when version in @supported_versions -> version
      _ -> nil
    end
  end
end

defmodule MyAppWeb.Plug.RequestTracer do
  @moduledoc """
  Assigns a unique trace ID to every inbound request and propagates it
  through the response headers. When an `X-Request-ID` header is provided
  by an upstream proxy or client, that value is used; otherwise a new UUID
  is generated. The trace ID is stored in the Logger metadata so all log
  lines emitted during the request carry it automatically.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @request_id_header "x-request-id"
  @max_header_length 200

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    trace_id = extract_or_generate(conn)

    Logger.metadata(request_id: trace_id)

    conn
    |> assign(:trace_id, trace_id)
    |> put_resp_header(@request_id_header, trace_id)
  end

  defp extract_or_generate(conn) do
    case get_req_header(conn, @request_id_header) do
      [id | _] when is_binary(id) and byte_size(id) <= @max_header_length ->
        sanitize(id)

      _ ->
        generate_trace_id()
    end
  end

  defp sanitize(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9\-_]/, "")
    |> String.slice(0, @max_header_length)
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
```
