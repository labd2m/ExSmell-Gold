```elixir
defmodule MyAppWeb.Plug.IdempotencyKey do
  @moduledoc """
  Enforces idempotency for non-idempotent HTTP methods (POST, PATCH, DELETE)
  via an `Idempotency-Key` request header. The first time a key is seen the
  request is processed normally and the response is stored. Subsequent
  requests with the same key and identical request fingerprint receive the
  cached response without re-executing the handler, preventing duplicate
  charges, duplicate sends, or duplicate mutations.

  Keys expire after a configurable TTL. Conflicting requests — same key
  but different body — are rejected with `422 Unprocessable Entity`.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.IdempotencyStore

  require Logger

  @idempotency_header "idempotency-key"
  @checked_methods ~w[POST PATCH DELETE]
  @default_ttl_seconds 86_400
  @max_key_length 255

  @impl Plug
  def init(opts), do: Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, ttl) when method in @checked_methods do
    case get_req_header(conn, @idempotency_header) do
      [] -> conn
      [key | _] -> handle_idempotent(conn, sanitize_key(key), ttl)
    end
  end

  def call(conn, _ttl), do: conn

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_idempotent(conn, key, _ttl) when byte_size(key) > @max_key_length do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:bad_request, Jason.encode!(%{error: "idempotency_key_too_long"}))
    |> halt()
  end

  defp handle_idempotent(conn, key, ttl) do
    fingerprint = request_fingerprint(conn)

    case IdempotencyStore.lookup(key) do
      {:ok, %{fingerprint: ^fingerprint, response: cached}} ->
        Logger.debug("Idempotent replay", key: key)
        replay_response(conn, cached)

      {:ok, %{fingerprint: stored_fp}} when stored_fp != fingerprint ->
        Logger.warning("Idempotency key conflict", key: key)
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unprocessable_entity, Jason.encode!(%{error: "idempotency_key_conflict"}))
        |> halt()

      :not_found ->
        conn
        |> assign(:idempotency_key, key)
        |> assign(:idempotency_fingerprint, fingerprint)
        |> assign(:idempotency_ttl, ttl)
        |> register_before_send(&cache_response(&1, key, fingerprint, ttl))
    end
  end

  defp replay_response(conn, %{status: status, headers: headers, body: body}) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)

    conn
    |> put_resp_header("idempotent-replayed", "true")
    |> send_resp(status, body)
    |> halt()
  end

  defp cache_response(conn, key, fingerprint, ttl) do
    if conn.status in 200..299 do
      {:ok, body, _conn} = read_body(conn)

      response = %{
        status: conn.status,
        headers: conn.resp_headers,
        body: body
      }

      IdempotencyStore.put(key, %{fingerprint: fingerprint, response: response}, ttl)
    end

    conn
  end

  defp request_fingerprint(conn) do
    {:ok, body, _conn} = read_body(conn)
    path = conn.request_path
    :crypto.hash(:sha256, path <> body) |> Base.encode16(case: :lower)
  end

  defp sanitize_key(key), do: String.trim(key)
end
```
