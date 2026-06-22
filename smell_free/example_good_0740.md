```elixir
defmodule Gateway.Plugs.BodySizeLimit do
  @moduledoc """
  Enforces a maximum request body size and halts oversized requests with
  HTTP 413 before any application logic runs.

  The body is read in a single call with the limit passed to `Plug.Conn.read_body/2`.
  When the body fits within the limit, it is stored in `conn.assigns` under
  `:raw_body` so that downstream Plugs (such as webhook signature verifiers)
  can access it without triggering a second read. When the body exceeds the
  limit, the connection is halted immediately.
  """

  @behaviour Plug

  alias Plug.Conn

  @default_limit_bytes 4 * 1_024 * 1_024

  @impl Plug
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit_bytes),
      skip_methods: Keyword.get(opts, :skip_methods, ["GET", "HEAD", "DELETE", "OPTIONS"])
    }
  end

  @impl Plug
  def call(%Conn{method: method} = conn, %{skip_methods: skip_methods} = config) do
    if method in skip_methods do
      conn
    else
      enforce_limit(conn, config)
    end
  end

  defp enforce_limit(conn, %{limit: limit}) do
    case Conn.read_body(conn, length: limit, read_length: limit, read_timeout: 5_000) do
      {:ok, body, conn} when byte_size(body) <= limit ->
        Conn.assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        reject(conn, limit)

      {:error, reason} ->
        reject_with_reason(conn, reason)
    end
  end

  defp reject(conn, limit_bytes) do
    limit_kb = div(limit_bytes, 1_024)
    body = Jason.encode!(%{error: "Request body exceeds the #{limit_kb} KB limit"})

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(413, body)
    |> Conn.halt()
  end

  defp reject_with_reason(conn, reason) do
    body = Jason.encode!(%{error: "Failed to read request body", detail: inspect(reason)})

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(400, body)
    |> Conn.halt()
  end
end

defmodule Gateway.Plugs.BodySizeLimit.PerRoute do
  @moduledoc """
  Helper for applying per-route body size limits in Phoenix routers.

  Usage:
      pipeline :upload do
        plug Gateway.Plugs.BodySizeLimit, limit: 50 * 1024 * 1024
      end

      pipeline :api do
        plug Gateway.Plugs.BodySizeLimit, limit: 1 * 1024 * 1024
      end
  """

  @spec limit_for(String.t()) :: pos_integer()
  def limit_for("upload"), do: 50 * 1_024 * 1_024
  def limit_for("api"), do: 1 * 1_024 * 1_024
  def limit_for(_), do: 4 * 1_024 * 1_024
end
```
