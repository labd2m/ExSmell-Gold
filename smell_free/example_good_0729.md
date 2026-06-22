```elixir
defmodule AppWeb.Plugs.ResponseCompression do
  @moduledoc """
  A Plug that compresses HTTP responses using gzip or deflate encoding
  when the client advertises support via the `Accept-Encoding` header.

  Compression is applied only to responses whose content type and size
  exceed configurable thresholds, avoiding the overhead of compressing
  already-small or already-compressed payloads.
  """

  import Plug.Conn

  @behaviour Plug

  @compressible_types ~w[
    application/json
    application/javascript
    text/html
    text/plain
    text/css
    text/xml
    application/xml
    image/svg+xml
  ]

  @default_min_size_bytes 1_024

  @impl Plug
  def init(opts) do
    %{
      min_size: Keyword.get(opts, :min_size, @default_min_size_bytes),
      types: Keyword.get(opts, :compressible_types, @compressible_types)
    }
  end

  @impl Plug
  def call(conn, opts) do
    register_before_send(conn, &maybe_compress(&1, opts))
  end

  defp maybe_compress(conn, %{min_size: min_size, types: types}) do
    with :ok <- check_content_type(conn, types),
         :ok <- check_size(conn, min_size),
         {:ok, encoding} <- negotiate_encoding(conn) do
      compress(conn, encoding)
    else
      _ -> conn
    end
  end

  defp check_content_type(conn, allowed_types) do
    content_type =
      conn
      |> get_resp_header("content-type")
      |> List.first("")
      |> String.split(";")
      |> List.first()
      |> String.trim()

    if content_type in allowed_types, do: :ok, else: :skip
  end

  defp check_size(conn, min_size) do
    body = conn.resp_body || ""
    if byte_size(body) >= min_size, do: :ok, else: :skip
  end

  defp negotiate_encoding(conn) do
    accepted =
      conn
      |> get_req_header("accept-encoding")
      |> List.first("")
      |> String.downcase()

    cond do
      already_encoded?(conn) -> :skip
      String.contains?(accepted, "gzip") -> {:ok, :gzip}
      String.contains?(accepted, "deflate") -> {:ok, :deflate}
      true -> :skip
    end
  end

  defp already_encoded?(conn) do
    conn |> get_resp_header("content-encoding") |> Enum.any?(&(&1 != "identity"))
  end

  defp compress(conn, encoding) do
    compressed = encode(conn.resp_body || "", encoding)
    encoding_name = encoding_header(encoding)

    conn
    |> put_resp_header("content-encoding", encoding_name)
    |> put_resp_header("vary", "Accept-Encoding")
    |> delete_resp_header("content-length")
    |> Map.put(:resp_body, compressed)
  end

  defp encode(body, :gzip), do: :zlib.gzip(body)
  defp encode(body, :deflate) do
    z = :zlib.open()
    :zlib.deflateInit(z, :default)
    compressed = :zlib.deflate(z, body, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(compressed)
  end

  defp encoding_header(:gzip), do: "gzip"
  defp encoding_header(:deflate), do: "deflate"
end
```
