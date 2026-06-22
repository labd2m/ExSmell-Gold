**File:** `example_good_1061.md`

```elixir
defmodule ApiWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug that enforces per-client rate limits using a sliding window strategy.
  Clients are identified by their API key or remote IP address. Responses
  include standard rate-limit headers so clients can backoff gracefully.
  """

  import Plug.Conn

  alias ApiWeb.RateLimiter.Store

  @behaviour Plug

  @default_limit 100
  @default_window_seconds 60

  @impl Plug
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      window_seconds: Keyword.get(opts, :window_seconds, @default_window_seconds),
      key_fn: Keyword.get(opts, :key_fn, &default_key/1)
    }
  end

  @impl Plug
  def call(conn, %{limit: limit, window_seconds: window_seconds, key_fn: key_fn}) do
    client_key = key_fn.(conn)

    case Store.check_and_increment(client_key, limit, window_seconds) do
      {:allow, remaining, reset_at} ->
        conn
        |> put_rate_limit_headers(limit, remaining, reset_at)

      {:deny, reset_at} ->
        conn
        |> put_rate_limit_headers(limit, 0, reset_at)
        |> send_resp(429, encode_error("Rate limit exceeded. Retry after #{reset_at}."))
        |> halt()
    end
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset_at) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(reset_at))
  end

  defp default_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] -> "api_key:#{key}"
      [] -> "ip:#{format_ip(conn.remote_ip)}"
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> Tuple.to_list() |> Enum.join(".")

  defp encode_error(message), do: Jason.encode!(%{error: message})
end

defmodule ApiWeb.RateLimiter.Store do
  @moduledoc """
  ETS-backed sliding window counter store for rate limit tracking.
  Entries are keyed by client identifier and store hit counts with expiry timestamps.
  """

  use GenServer

  @table :rate_limiter_store
  @cleanup_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_and_increment(String.t(), pos_integer(), pos_integer()) ::
          {:allow, non_neg_integer(), integer()} | {:deny, integer()}
  def check_and_increment(key, limit, window_seconds) when is_binary(key) do
    now = System.system_time(:second)
    window_start = now - window_seconds
    reset_at = now + window_seconds

    current_count = prune_and_count(key, window_start)

    if current_count < limit do
      :ets.insert(@table, {{key, now}, 1})
      {:allow, limit - current_count - 1, reset_at}
    else
      {:deny, reset_at}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:second) - 3600
    prune_before(cutoff)
    schedule_cleanup()
    {:noreply, state}
  end

  defp prune_and_count(key, window_start) do
    match_spec = [{{{{key, :"$1"}, :_}}, [{:>=, :"$1", window_start}], [true]}]

    :ets.select_delete(@table, [{{{{key, :"$1"}, :_}}, [{:<, :"$1", window_start}], [true]}])
    :ets.select_count(@table, match_spec)
  end

  defp prune_before(cutoff) do
    :ets.select_delete(@table, [{{{{:_, :"$1"}, :_}}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
