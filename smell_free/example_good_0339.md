```elixir
defmodule AppWeb.Plugs.HttpCaching do
  @moduledoc """
  A Plug that adds HTTP caching semantics to GET and HEAD responses via
  ETag and Last-Modified headers.

  On each qualifying response the Plug computes a strong ETag from the
  response body. If the client sends a matching `If-None-Match` header,
  a `304 Not Modified` is returned without a body, saving bandwidth.

  Cache-Control directives are configurable per-route via options.
  """

  import Plug.Conn

  @behaviour Plug

  @type opt ::
          {:max_age, non_neg_integer()}
          | {:private, boolean()}
          | {:no_store, boolean()}

  @cacheable_methods ~w[GET HEAD]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: method} = conn, opts) when method in @cacheable_methods do
    conn
    |> register_before_send(&maybe_apply_caching(&1, opts))
  end

  def call(conn, _opts), do: conn

  defp maybe_apply_caching(conn, opts) do
    if cacheable_status?(conn.status) do
      conn
      |> put_cache_control(opts)
      |> put_etag_header()
      |> check_conditional_request()
    else
      conn
    end
  end

  defp cacheable_status?(status) when status in 200..206, do: true
  defp cacheable_status?(_), do: false

  defp put_cache_control(conn, opts) do
    directive = build_cache_control(opts)
    put_resp_header(conn, "cache-control", directive)
  end

  defp build_cache_control(opts) do
    cond do
      Keyword.get(opts, :no_store, false) ->
        "no-store"

      Keyword.get(opts, :private, false) ->
        max_age = Keyword.get(opts, :max_age, 0)
        "private, max-age=#{max_age}"

      true ->
        max_age = Keyword.get(opts, :max_age, 60)
        "public, max-age=#{max_age}"
    end
  end

  defp put_etag_header(%{resp_body: body} = conn) when is_binary(body) do
    etag = compute_etag(body)
    put_resp_header(conn, "etag", etag)
  end

  defp put_etag_header(conn), do: conn

  defp check_conditional_request(conn) do
    client_etag = conn |> get_req_header("if-none-match") |> List.first()
    server_etag = conn |> get_resp_header("etag") |> List.first()

    if client_etag && server_etag && etags_match?(client_etag, server_etag) do
      conn
      |> delete_resp_header("content-type")
      |> delete_resp_header("content-length")
      |> Map.put(:resp_body, "")
      |> Map.put(:status, 304)
    else
      conn
    end
  end

  defp etags_match?(client, server) do
    normalize_etag(client) == normalize_etag(server)
  end

  defp normalize_etag(etag) do
    etag
    |> String.trim()
    |> String.trim_leading("W/")
    |> String.trim("\"")
  end

  defp compute_etag(body) do
    hash =
      :crypto.hash(:sha256, body)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "\"#{hash}\""
  end
end
```
