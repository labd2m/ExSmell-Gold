```elixir
defmodule API.Plug.RateLimiter do
  @moduledoc """
  A Plug that enforces per-client rate limiting using a token bucket strategy.
  Limit configuration is passed through Plug options rather than application
  environment, allowing different router scopes to apply different limits.
  """

  @behaviour Plug

  import Plug.Conn

  alias API.RateLimit.{Bucket, BucketStore}

  @type opts :: [
          requests_per_minute: pos_integer(),
          client_id_header: String.t(),
          store: module()
        ]

  @doc "Initializes the plug options with defaults."
  @impl Plug
  @spec init(opts()) :: opts()
  def init(opts) do
    opts
    |> Keyword.put_new(:requests_per_minute, 60)
    |> Keyword.put_new(:client_id_header, "x-client-id")
    |> Keyword.put_new(:store, BucketStore)
  end

  @doc "Checks the rate limit for the incoming request."
  @impl Plug
  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    limit = Keyword.fetch!(opts, :requests_per_minute)
    header = Keyword.fetch!(opts, :client_id_header)
    store = Keyword.fetch!(opts, :store)

    case extract_client_id(conn, header) do
      {:ok, client_id} -> enforce_limit(conn, client_id, limit, store)
      {:error, :missing_header} -> reject_unauthorized(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec extract_client_id(Plug.Conn.t(), String.t()) ::
          {:ok, String.t()} | {:error, :missing_header}
  defp extract_client_id(conn, header) do
    case get_req_header(conn, header) do
      [client_id | _] when is_binary(client_id) and client_id != "" -> {:ok, client_id}
      _ -> {:error, :missing_header}
    end
  end

  @spec enforce_limit(Plug.Conn.t(), String.t(), pos_integer(), module()) :: Plug.Conn.t()
  defp enforce_limit(conn, client_id, limit, store) do
    case store.consume(client_id, limit) do
      {:ok, %Bucket{remaining: remaining, reset_at: reset_at}} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
        |> put_resp_header("x-ratelimit-reset", Integer.to_string(reset_at))

      {:error, %Bucket{reset_at: reset_at}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(reset_at - unix_now()))
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limit_exceeded"}))
        |> halt()
    end
  end

  @spec reject_unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  defp reject_unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"missing_client_id"}))
    |> halt()
  end

  @spec unix_now() :: integer()
  defp unix_now, do: System.system_time(:second)
end

defmodule API.RateLimit.Bucket do
  @moduledoc "Represents the current state of a rate limit bucket."

  defstruct [:client_id, :remaining, :reset_at]

  @type t :: %__MODULE__{
          client_id: String.t(),
          remaining: non_neg_integer(),
          reset_at: integer()
        }
end
```
