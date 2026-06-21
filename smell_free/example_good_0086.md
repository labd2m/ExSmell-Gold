# File: `example_good_86.md`

```elixir
defmodule Plug.RequestThrottler do
  @moduledoc """
  Plug middleware that enforces per-client request rate limits.

  The client identity is determined by a configurable extractor function,
  defaulting to the remote IP address. When a client exceeds the
  configured limit, the plug halts the connection with a 429 response
  and a `Retry-After` header.

  Rate limit state is delegated to `Notifications.RateLimiter` so that
  limit logic remains in one place and is reusable outside HTTP contexts.
  """

  @behaviour Plug

  import Plug.Conn

  alias Notifications.RateLimiter

  @default_retry_after_seconds 60

  @type opts :: %{
          limiter: module(),
          client_id_fn: (Plug.Conn.t() -> String.t()),
          retry_after_seconds: pos_integer()
        }

  @impl Plug
  def init(opts) when is_list(opts) do
    %{
      limiter: Keyword.get(opts, :limiter, RateLimiter),
      client_id_fn: Keyword.get(opts, :client_id_fn, &default_client_id/1),
      retry_after_seconds: Keyword.get(opts, :retry_after_seconds, @default_retry_after_seconds)
    }
  end

  @impl Plug
  def call(conn, opts) do
    client_id = opts.client_id_fn.(conn)

    case opts.limiter.check(client_id) do
      :allow -> conn
      :deny -> reject_request(conn, opts.retry_after_seconds)
    end
  end

  @doc """
  Extracts a client identity string from request headers, preferring
  `X-Forwarded-For` over the direct remote IP.

  Suitable for use as a custom `:client_id_fn` in API gateway deployments
  where the real client IP is forwarded by a load balancer.
  """
  @spec forwarded_ip_extractor(Plug.Conn.t()) :: String.t()
  def forwarded_ip_extractor(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> extract_first_forwarded_ip()
    |> fallback_to_remote_ip(conn)
  end

  @doc """
  Extracts the client identity from a verified JWT subject claim.

  Expects the connection to have a `:current_user` assign with an `:id` key
  set by upstream authentication middleware.
  """
  @spec authenticated_user_extractor(Plug.Conn.t()) :: String.t()
  def authenticated_user_extractor(%Plug.Conn{assigns: %{current_user: %{id: id}}})
      when is_binary(id) do
    id
  end

  def authenticated_user_extractor(conn) do
    default_client_id(conn)
  end

  defp reject_request(conn, retry_after_seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> put_resp_header("content-type", "application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded"}))
    |> halt()
  end

  defp default_client_id(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp extract_first_forwarded_ip([header | _rest]) do
    header
    |> String.split(",")
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      ip -> ip
    end
  end

  defp extract_first_forwarded_ip([]), do: nil

  defp fallback_to_remote_ip(nil, conn), do: default_client_id(conn)
  defp fallback_to_remote_ip(ip, _conn), do: ip
end
```
