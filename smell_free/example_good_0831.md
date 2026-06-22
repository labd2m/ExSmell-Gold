```elixir
defmodule MyAppWeb.Plug.BodySizeLimit do
  @moduledoc """
  Enforces a maximum request body size before the body is fully read into
  memory. Rather than reading the whole payload and then checking, this plug
  reads the body in chunks and halts as soon as the accumulated size exceeds
  the configured limit, preventing memory exhaustion on deliberately oversized
  requests. Each pipeline can declare its own limit so file-upload endpoints
  get a generous allowance while JSON API endpoints stay tight.

  ## Usage

      plug MyAppWeb.Plug.BodySizeLimit, max_bytes: 1_048_576
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @default_max_bytes 1 * 1024 * 1024
  @chunk_length 65_536

  @impl Plug
  def init(opts) do
    %{max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)}
  end

  @impl Plug
  def call(conn, %{max_bytes: max_bytes}) do
    content_length = content_length(conn)

    cond do
      content_length != nil and content_length > max_bytes ->
        reject(conn, max_bytes)

      true ->
        conn
        |> read_and_cache(max_bytes)
        |> handle_read_result(max_bytes)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp read_and_cache(conn, max_bytes) do
    read_chunks(conn, max_bytes, 0, [])
  end

  defp read_chunks(conn, max_bytes, accumulated, chunks) do
    case read_body(conn, length: @chunk_length) do
      {:ok, chunk, conn} ->
        new_total = accumulated + byte_size(chunk)

        if new_total > max_bytes do
          {:too_large, conn}
        else
          {:ok, IO.iodata_to_binary([chunks, chunk]), conn}
        end

      {:more, chunk, conn} ->
        new_total = accumulated + byte_size(chunk)

        if new_total > max_bytes do
          {:too_large, conn}
        else
          read_chunks(conn, max_bytes, new_total, [chunks, chunk])
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp handle_read_result({:ok, body, conn}, _max_bytes) do
    assign(conn, :raw_body, body)
  end

  defp handle_read_result({:too_large, conn}, max_bytes) do
    Logger.warning("Request body exceeds size limit",
      max_bytes: max_bytes,
      path: conn.request_path,
      remote_ip: format_ip(conn.remote_ip)
    )

    reject(conn, max_bytes)
  end

  defp handle_read_result({:error, reason, conn}, _max_bytes) do
    Logger.error("Failed to read request body", reason: inspect(reason))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:bad_request, Jason.encode!(%{error: "body_read_failed"}))
    |> halt()
  end

  defp reject(conn, max_bytes) do
    mb = Float.round(max_bytes / (1024 * 1024), 1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      :request_entity_too_large,
      Jason.encode!(%{
        error: "payload_too_large",
        message: "Request body exceeds the #{mb} MB limit for this endpoint"
      })
    )
    |> halt()
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: :inet.ntoa(ip) |> to_string()
end
```
