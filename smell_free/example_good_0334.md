```elixir
defmodule AppWeb.Plugs.IdempotencyKey do
  @moduledoc """
  A Plug that enforces idempotency for mutating HTTP requests.

  When a request arrives with an `Idempotency-Key` header, the Plug checks
  the cache for a prior response. If one exists, it replays it immediately
  without invoking downstream handlers. On a first-seen key, the response
  is captured after processing and stored for subsequent replays.

  Keys are scoped to the authenticated account to prevent cross-account
  replay attacks.
  """

  import Plug.Conn

  alias Platform.IdempotencyStore

  @behaviour Plug

  @safe_methods ~w[GET HEAD OPTIONS TRACE]
  @max_key_bytes 255

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: method} = conn, _opts) when method in @safe_methods, do: conn

  def call(conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [] -> conn
      [key | _] -> enforce_idempotency(conn, key)
    end
  end

  defp enforce_idempotency(conn, key) when byte_size(key) > @max_key_bytes do
    reject(conn, 400, "idempotency key must not exceed #{@max_key_bytes} bytes")
  end

  defp enforce_idempotency(conn, key) do
    account_id = conn.assigns[:current_account] && conn.assigns.current_account.id
    scoped_key = build_scoped_key(account_id, conn.request_path, key)

    case IdempotencyStore.fetch(scoped_key) do
      {:ok, cached} -> replay_response(conn, cached)
      {:error, :not_found} -> process_and_cache(conn, scoped_key)
    end
  end

  defp process_and_cache(conn, scoped_key) do
    conn
    |> register_before_send(fn sent_conn ->
      if sent_conn.status in 200..299 do
        IdempotencyStore.store(scoped_key, capture_response(sent_conn))
      end

      sent_conn
    end)
  end

  defp replay_response(conn, %{status: status, body: body, content_type: ct}) do
    conn
    |> put_resp_content_type(ct)
    |> put_resp_header("idempotent-replayed", "true")
    |> send_resp(status, body)
    |> halt()
  end

  defp capture_response(conn) do
    content_type =
      conn
      |> get_resp_header("content-type")
      |> List.first("application/json")

    %{
      status: conn.status,
      body: conn.resp_body,
      content_type: content_type,
      captured_at: DateTime.utc_now()
    }
  end

  defp build_scoped_key(nil, path, key) do
    "anon:#{path}:#{key}"
  end

  defp build_scoped_key(account_id, path, key) do
    "account:#{account_id}:#{path}:#{key}"
  end

  defp reject(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end

defmodule Platform.IdempotencyStore do
  @moduledoc """
  A GenServer-backed store for idempotency key responses with TTL expiry.
  Delegates to the application cache layer with a fixed TTL window.
  """

  @ttl_ms :timer.hours(24)

  @type cached_response :: %{status: non_neg_integer(), body: binary(), content_type: String.t()}

  @spec fetch(String.t()) :: {:ok, cached_response()} | {:error, :not_found}
  def fetch(key) when is_binary(key), do: Platform.Cache.fetch({"idempotency", key})

  @spec store(String.t(), cached_response()) :: :ok
  def store(key, response) when is_binary(key) and is_map(response) do
    Platform.Cache.put({"idempotency", key}, response, @ttl_ms)
  end
end
```
