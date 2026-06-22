```elixir
defmodule Web.Plugs.IdempotencyGuard do
  @moduledoc """
  A Plug that enforces idempotent request handling for state-mutating
  endpoints. Requests carrying an Idempotency-Key header are deduplicated:
  a cached response is returned for repeated keys within the retention window.
  """

  import Plug.Conn

  alias Idempotency.{ResponseCache, KeyValidator}

  @behaviour Plug

  @idempotency_header "idempotency-key"
  @retention_seconds 86_400

  @type opts :: [enforce_for: [String.t()]]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    enforce_methods = Keyword.get(opts, :enforce_for, ["POST", "PUT", "PATCH"])

    if conn.method in enforce_methods do
      handle_idempotent_request(conn)
    else
      conn
    end
  end

  @spec handle_idempotent_request(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_idempotent_request(conn) do
    case get_req_header(conn, @idempotency_header) do
      [raw_key] -> process_with_key(conn, raw_key)
      [] -> conn
    end
  end

  @spec process_with_key(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp process_with_key(conn, raw_key) do
    case KeyValidator.validate(raw_key) do
      {:ok, key} -> lookup_or_continue(conn, key)
      {:error, _} -> reject_invalid_key(conn)
    end
  end

  @spec lookup_or_continue(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp lookup_or_continue(conn, key) do
    case ResponseCache.fetch(key) do
      {:ok, cached} ->
        replay_cached_response(conn, cached)

      {:error, :not_found} ->
        conn
        |> assign(:idempotency_key, key)
        |> register_after_send(&cache_response(&1, key))
    end
  end

  @spec replay_cached_response(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp replay_cached_response(conn, cached) do
    body = Jason.encode!(cached.body)

    cached.headers
    |> Enum.reduce(conn, fn {name, value}, c -> put_resp_header(c, name, value) end)
    |> put_resp_header("x-idempotent-replayed", "true")
    |> put_resp_content_type("application/json")
    |> send_resp(cached.status, body)
    |> halt()
  end

  @spec cache_response(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp cache_response(conn, key) do
    cacheable = %{
      status: conn.status,
      body: conn.resp_body,
      headers: conn.resp_headers
    }

    ResponseCache.store(key, cacheable, @retention_seconds)
    conn
  end

  @spec reject_invalid_key(Plug.Conn.t()) :: Plug.Conn.t()
  defp reject_invalid_key(conn) do
    body = Jason.encode!(%{error: "Invalid Idempotency-Key format"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, body)
    |> halt()
  end
end
```
