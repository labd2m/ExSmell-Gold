```elixir
defmodule AppWeb.Plugs.RateLimitHeaders do
  @moduledoc """
  A Plug that injects standard `X-RateLimit-*` response headers informing
  clients about their current rate limit status.

  Works in concert with a rate limiting backend (e.g., `Gateway.RateLimiter`)
  by reading limit state from `conn.assigns` after the rate check has run,
  or by querying the limiter directly with the request's identity.
  """

  import Plug.Conn

  @behaviour Plug

  @header_limit "x-ratelimit-limit"
  @header_remaining "x-ratelimit-remaining"
  @header_reset "x-ratelimit-reset"
  @header_retry_after "retry-after"
  @header_policy "x-ratelimit-policy"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    limiter = Keyword.get(opts, :limiter, Gateway.RateLimiter)
    bucket_fn = Keyword.get(opts, :bucket_fn, &default_bucket/1)
    limit = Keyword.get(opts, :limit, 1_000)
    window_seconds = Keyword.get(opts, :window_seconds, 3_600)

    bucket = bucket_fn.(conn)

    case limiter.consume(bucket, 1) do
      {:ok, remaining} ->
        reset_at = next_window_unix(window_seconds)

        conn
        |> put_resp_header(@header_limit, to_string(limit))
        |> put_resp_header(@header_remaining, to_string(remaining))
        |> put_resp_header(@header_reset, to_string(reset_at))
        |> put_resp_header(@header_policy, "#{limit};w=#{window_seconds}")
        |> assign(:rate_limit_remaining, remaining)

      {:error, :rate_limited} ->
        reset_at = next_window_unix(window_seconds)

        conn
        |> put_resp_header(@header_limit, to_string(limit))
        |> put_resp_header(@header_remaining, "0")
        |> put_resp_header(@header_reset, to_string(reset_at))
        |> put_resp_header(@header_retry_after, to_string(window_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
            error: "rate_limited",
            message: "Too many requests. Please retry after #{window_seconds} seconds.",
            reset_at: reset_at
          }))
        |> halt()

      {:error, :unknown_bucket} ->
        limiter.register(bucket, %{capacity: limit})
        conn
    end
  end

  @doc "Builds a bucket identifier from the remote IP address."
  @spec ip_bucket(Plug.Conn.t()) :: String.t()
  def ip_bucket(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "ip:#{ip}"
  end

  @doc "Builds a bucket identifier from the authenticated account id."
  @spec account_bucket(Plug.Conn.t()) :: String.t()
  def account_bucket(conn) do
    case conn.assigns[:current_account] do
      nil -> ip_bucket(conn)
      account -> "account:#{account.id}"
    end
  end

  @doc "Builds a bucket identifier scoped to both account and endpoint path."
  @spec endpoint_bucket(Plug.Conn.t()) :: String.t()
  def endpoint_bucket(conn) do
    base = account_bucket(conn)
    path_prefix = conn.request_path |> String.split("/") |> Enum.take(3) |> Enum.join("/")
    "#{base}:#{path_prefix}"
  end

  defp default_bucket(conn), do: account_bucket(conn)

  defp next_window_unix(window_seconds) do
    now = System.os_time(:second)
    window_start = div(now, window_seconds) * window_seconds
    window_start + window_seconds
  end
end
```
