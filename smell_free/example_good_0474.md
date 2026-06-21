```elixir
defmodule Gateway.Plugs.Compression do
  @moduledoc """
  Compresses HTTP response bodies using gzip when the client advertises
  support via the `Accept-Encoding` header.

  Only responses whose `Content-Type` appears in the configured allow-list
  are compressed; binary content types such as images and video are excluded
  because they are already compressed and re-compressing wastes CPU. A
  minimum body size threshold prevents adding gzip framing overhead to
  responses smaller than the compressed output would be.
  """

  @behaviour Plug

  alias Plug.Conn

  @default_min_size 1_024
  @default_compressible_types ~w(
    application/json
    application/javascript
    text/html
    text/css
    text/plain
    text/xml
    application/xml
    application/x-www-form-urlencoded
  )

  @impl Plug
  def init(opts) do
    %{
      min_size: Keyword.get(opts, :min_size, @default_min_size),
      compressible_types: Keyword.get(opts, :compressible_types, @default_compressible_types)
    }
  end

  @impl Plug
  def call(%Conn{} = conn, config) do
    if accepts_gzip?(conn) do
      Conn.register_before_send(conn, &maybe_compress(&1, config))
    else
      conn
    end
  end

  defp accepts_gzip?(conn) do
    conn
    |> Conn.get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end

  defp maybe_compress(%Conn{resp_body: body} = conn, config) do
    content_type = conn |> Conn.get_resp_header("content-type") |> List.first("")
    body_binary = IO.iodata_to_binary(body)

    if compressible?(content_type, config.compressible_types) and
         byte_size(body_binary) >= config.min_size do
      compress(conn, body_binary)
    else
      conn
    end
  end

  defp compress(conn, body) do
    compressed = :zlib.gzip(body)

    if byte_size(compressed) < byte_size(body) do
      conn
      |> Conn.put_resp_header("content-encoding", "gzip")
      |> Conn.put_resp_header("content-length", Integer.to_string(byte_size(compressed)))
      |> Conn.delete_resp_header("transfer-encoding")
      |> Map.put(:resp_body, compressed)
    else
      conn
    end
  end

  defp compressible?(content_type, allowed_types) do
    Enum.any?(allowed_types, &String.starts_with?(content_type, &1))
  end
end
```
