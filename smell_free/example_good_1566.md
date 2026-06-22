```elixir
defmodule Gateway.Plug.RateLimiter do
  @moduledoc """
  Plug-based rate limiter middleware for the API gateway.

  Enforces per-client request rate limits using a sliding window algorithm
  backed by a shared ETS counter store. Rejected requests receive a
  structured JSON error response with retry guidance.
  """

  @behaviour Plug

  import Plug.Conn

  alias Gateway.RateLimit.{WindowStore, ClientResolver}

  @default_limit 100
  @default_window_seconds 60

  @type opts :: %{
          limit: pos_integer(),
          window_seconds: pos_integer()
        }

  @impl Plug
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      window_seconds: Keyword.get(opts, :window_seconds, @default_window_seconds)
    }
  end

  @impl Plug
  def call(conn, %{limit: limit, window_seconds: window_seconds} = _opts) do
    client_key = ClientResolver.resolve(conn)

    case WindowStore.check_and_increment(client_key, limit, window_seconds) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(429, encode_error("rate_limit_exceeded", retry_after))
        |> halt()
    end
  end

  defp encode_error(code, retry_after) do
    Jason.encode!(%{
      error: %{
        code: code,
        message: "Request rate limit exceeded.",
        retry_after_seconds: retry_after
      }
    })
  end
end

defmodule Gateway.RateLimit.WindowStore do
  @moduledoc """
  ETS-backed sliding window counter for rate limit tracking.
  """

  @table :gateway_rate_limit_windows

  @doc """
  Checks the current request count for a client and increments if under limit.

  Returns `{:ok, remaining}` or `{:error, :rate_limited, retry_after_seconds}`.
  """
  @spec check_and_increment(String.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :rate_limited, pos_integer()}
  def check_and_increment(client_key, limit, window_seconds) do
    now = System.system_time(:second)
    window_start = now - window_seconds

    prune_expired(client_key, window_start)

    current_count = count_requests(client_key, window_start)

    if current_count < limit do
      :ets.insert(@table, {{client_key, now}, now})
      {:ok, limit - current_count - 1}
    else
      oldest = oldest_request(client_key)
      retry_after = window_seconds - (now - oldest)
      {:error, :rate_limited, max(retry_after, 1)}
    end
  end

  defp prune_expired(client_key, window_start) do
    :ets.select_delete(@table, [
      {{{client_key, :"$1"}, :"$1"}, [{:<, :"$1", window_start}], [true]}
    ])
  end

  defp count_requests(client_key, window_start) do
    :ets.select_count(@table, [
      {{{client_key, :"$1"}, :"$1"}, [{:>=, :"$1", window_start}], [true]}
    ])
  end

  defp oldest_request(client_key) do
    case :ets.select(@table, [
           {{{client_key, :"$1"}, :"$1"}, [], [:"$1"]}
         ]) do
      [] -> System.system_time(:second)
      timestamps -> Enum.min(timestamps)
    end
  end
end
```
