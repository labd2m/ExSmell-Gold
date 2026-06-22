```elixir
defmodule Platform.RateLimitPlug do
  @moduledoc """
  Enforces request rate limits per authenticated user or IP address.
  Limits are applied per-route using opts configuration so different
  endpoints can have different policies. Requests that exceed the limit
  receive a 429 response with a `Retry-After` header. The underlying
  token bucket state is managed by `RateLimiter.TokenBucket`.
  """

  @behaviour Plug

  import Plug.Conn

  alias RateLimiter.TokenBucket

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      capacity: Keyword.get(opts, :capacity, 100),
      refill_per_second: Keyword.get(opts, :refill_per_second, 10),
      key_fn: Keyword.get(opts, :key_fn, &default_key/1)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %{capacity: cap, refill_per_second: rps, key_fn: key_fn}) do
    bucket_key = key_fn.(conn)
    bucket_config = %{capacity: cap, refill_per_second: rps}

    case TokenBucket.consume(bucket_key, bucket_config) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        retry_after = ceil(1 / rps)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded"}))
        |> halt()
    end
  end

  @doc """
  Returns a key function that scopes rate limiting to the current user when
  authenticated, falling back to the remote IP address for anonymous requests.
  """
  @spec user_or_ip_key() :: (Plug.Conn.t() -> String.t())
  def user_or_ip_key do
    fn conn ->
      case conn.assigns[:current_user] do
        %{id: user_id} -> "user:#{user_id}"
        nil -> "ip:#{remote_ip(conn)}"
      end
    end
  end

  @doc "Returns a key function that scopes rate limiting to the remote IP only."
  @spec ip_key() :: (Plug.Conn.t() -> String.t())
  def ip_key do
    fn conn -> "ip:#{remote_ip(conn)}" end
  end

  @doc "Returns a key function that scopes rate limiting per user per named route."
  @spec user_per_route_key(String.t()) :: (Plug.Conn.t() -> String.t())
  def user_per_route_key(route_name) when is_binary(route_name) do
    fn conn ->
      case conn.assigns[:current_user] do
        %{id: user_id} -> "user:#{user_id}:route:#{route_name}"
        nil -> "ip:#{remote_ip(conn)}:route:#{route_name}"
      end
    end
  end

  defp default_key(conn) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> "user:#{user_id}"
      nil -> "ip:#{remote_ip(conn)}"
    end
  end

  defp remote_ip(conn) do
    conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
  end
end
```
