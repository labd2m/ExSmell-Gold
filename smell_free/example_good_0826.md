```elixir
defmodule Gateway.Plugs.ReverseProxy do
  @moduledoc """
  A Plug that forwards incoming HTTP requests to a configured upstream
  host and streams the upstream response back to the client.

  Headers are forwarded in both directions, with a set of hop-by-hop
  headers stripped as required by RFC 7230. An `X-Forwarded-For` header
  is appended so the upstream can identify the originating client IP.
  Connection and upgrade headers are excluded to prevent protocol
  confusion in non-WebSocket paths.
  """

  @behaviour Plug

  alias Plug.Conn

  @hop_by_hop_headers ~w(
    connection keep-alive proxy-authenticate proxy-authorization
    te trailers transfer-encoding upgrade
  )

  @impl Plug
  def init(opts) do
    %{
      upstream: Keyword.fetch!(opts, :upstream),
      path_prefix: Keyword.get(opts, :strip_prefix, ""),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }
  end

  @impl Plug
  def call(%Conn{} = conn, config) do
    upstream_url = build_upstream_url(conn, config)
    req_headers = forward_headers(conn.req_headers, xff_header(conn))

    case make_request(conn.method, upstream_url, req_headers, conn, config.timeout_ms) do
      {:ok, status, resp_headers, body} ->
        clean_resp_headers = strip_hop_by_hop(resp_headers)

        conn
        |> set_response_headers(clean_resp_headers)
        |> Conn.send_resp(status, body)
        |> Conn.halt()

      {:error, reason} ->
        body = Jason.encode!(%{error: "Upstream request failed", detail: inspect(reason)})

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(502, body)
        |> Conn.halt()
    end
  end

  defp build_upstream_url(conn, %{upstream: upstream, path_prefix: prefix}) do
    path = conn.request_path |> String.replace_prefix(prefix, "")
    query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
    "#{upstream}#{path}#{query}"
  end

  defp forward_headers(headers, xff) do
    headers
    |> strip_hop_by_hop()
    |> then(&[xff | &1])
  end

  defp strip_hop_by_hop(headers) do
    Enum.reject(headers, fn {name, _} -> String.downcase(name) in @hop_by_hop_headers end)
  end

  defp xff_header(conn) do
    remote_ip = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    {"x-forwarded-for", remote_ip}
  end

  defp set_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Conn.put_resp_header(acc, String.downcase(name), value)
    end)
  end

  defp make_request(method, url, headers, conn, timeout_ms) do
    charlist_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    charlist_url = to_charlist(url)

    http_opts = [timeout: timeout_ms, connect_timeout: 5_000]

    request =
      case method do
        m when m in ["GET", "HEAD", "DELETE"] ->
          {charlist_url, charlist_headers}

        _ ->
          {:ok, body, _conn} = Conn.read_body(conn)
          content_type =
            conn |> Conn.get_req_header("content-type") |> List.first("application/octet-stream")

          {charlist_url, charlist_headers, to_charlist(content_type), body}
      end

    http_method = method |> String.downcase() |> String.to_existing_atom()

    case :httpc.request(http_method, request, http_opts, []) do
      {:ok, {{_, status, _}, resp_headers, body}} ->
        string_headers = Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        {:ok, status, string_headers, to_string(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
