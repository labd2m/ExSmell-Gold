**File:** `example_good_1412.md`

```elixir
defmodule ResponseCache.CachedResponse do
  @moduledoc "An immutable cached HTTP response with TTL metadata."

  @enforce_keys [:status, :headers, :body, :expires_at]
  defstruct [:status, :headers, :body, :expires_at]

  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          expires_at: integer()
        }

  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{expires_at: exp}) do
    System.monotonic_time(:millisecond) < exp
  end
end

defmodule ResponseCache.KeyBuilder do
  @moduledoc """
  Builds cache keys from a request connection, incorporating Vary
  headers to ensure correct per-variant caching.
  """

  @spec build(Plug.Conn.t(), [String.t()]) :: String.t()
  def build(%Plug.Conn{} = conn, vary_headers \\ []) do
    vary_values =
      Enum.map(vary_headers, fn header ->
        "#{header}=#{get_header(conn, header)}"
      end)

    parts = [conn.method, conn.request_path | vary_values]
    hash = :crypto.hash(:sha256, Enum.join(parts, "|")) |> Base.url_encode64(padding: false)
    "response_cache:#{hash}"
  end

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> value
      [] -> ""
    end
  end
end

defmodule ResponseCache.Store do
  @moduledoc "Agent-backed in-memory store for cached HTTP responses."

  use Agent

  alias ResponseCache.CachedResponse

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get(String.t()) :: {:ok, CachedResponse.t()} | :miss
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> :miss
      %CachedResponse{} = entry ->
        if CachedResponse.live?(entry), do: {:ok, entry}, else: :miss
    end
  end

  @spec put(String.t(), CachedResponse.t()) :: :ok
  def put(key, %CachedResponse{} = response) do
    Agent.update(__MODULE__, &Map.put(&1, key, response))
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(key), do: Agent.update(__MODULE__, &Map.delete(&1, key))

  @spec flush() :: :ok
  def flush, do: Agent.update(__MODULE__, fn _ -> %{} end)
end

defmodule ResponseCache.Plug do
  @moduledoc """
  A caching Plug that stores and replays GET responses based on
  a configurable TTL and optional Vary header list.
  Cacheable responses are stored before being sent to the client.
  """

  import Plug.Conn

  alias ResponseCache.{CachedResponse, KeyBuilder, Store}

  @default_ttl_ms :timer.minutes(5)
  @cacheable_methods ~w(GET HEAD)
  @cacheable_statuses 200..299

  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      vary: Keyword.get(opts, :vary, []),
      cache_control: Keyword.get(opts, :cache_control, true)
    }
  end

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    if conn.method in @cacheable_methods do
      serve_or_cache(conn, config)
    else
      conn
    end
  end

  defp serve_or_cache(conn, config) do
    cache_key = KeyBuilder.build(conn, config.vary)

    case Store.get(cache_key) do
      {:ok, cached} ->
        serve_cached(conn, cached)

      :miss ->
        conn
        |> register_before_send(&maybe_cache_response(&1, cache_key, config))
    end
  end

  defp serve_cached(conn, %CachedResponse{} = cached) do
    conn
    |> merge_resp_headers(cached.headers)
    |> put_resp_header("x-cache", "HIT")
    |> send_resp(cached.status, cached.body)
    |> halt()
  end

  defp maybe_cache_response(conn, cache_key, config) do
    if conn.status in @cacheable_statuses and is_binary(conn.resp_body) do
      expires_at = System.monotonic_time(:millisecond) + config.ttl_ms

      cached = %CachedResponse{
        status: conn.status,
        headers: conn.resp_headers,
        body: conn.resp_body,
        expires_at: expires_at
      }

      Store.put(cache_key, cached)

      if config.cache_control do
        put_resp_header(conn, "x-cache", "MISS")
      else
        conn
      end
    else
      conn
    end
  end
end
```
