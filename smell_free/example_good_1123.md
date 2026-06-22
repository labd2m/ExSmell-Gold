```elixir
defmodule Apigw.Plugs.BearerAuth do
  @moduledoc """
  Plug that extracts and validates a Bearer token from the Authorization header.
  On success, assigns the resolved principal to the connection. On failure,
  halts the pipeline and returns a structured 401 response.
  """

  import Plug.Conn

  alias Apigw.Auth.TokenStore

  @behaviour Plug

  @type opts :: [realm: String.t()]

  @impl Plug
  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    realm = Keyword.get(opts, :realm, "API")

    conn
    |> extract_token()
    |> resolve_principal()
    |> apply_result(conn, realm)
  end

  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_header}
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_header}
    end
  end

  @spec resolve_principal({:ok, String.t()} | {:error, atom()}) ::
          {:ok, map()} | {:error, :missing_header | :invalid_token | :expired_token}
  defp resolve_principal({:error, reason}), do: {:error, reason}

  defp resolve_principal({:ok, raw_token}) do
    TokenStore.lookup(raw_token)
  end

  @spec apply_result(
          {:ok, map()} | {:error, atom()},
          Plug.Conn.t(),
          String.t()
        ) :: Plug.Conn.t()
  defp apply_result({:ok, principal}, conn, _realm) do
    assign(conn, :current_principal, principal)
  end

  defp apply_result({:error, reason}, conn, realm) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("www-authenticate", ~s(Bearer realm="#{realm}"))
    |> send_resp(401, encode_error(reason))
    |> halt()
  end

  @spec encode_error(atom()) :: String.t()
  defp encode_error(:missing_header), do: ~s({"error":"authorization_required"})
  defp encode_error(:invalid_token), do: ~s({"error":"invalid_token"})
  defp encode_error(:expired_token), do: ~s({"error":"token_expired"})
  defp encode_error(_), do: ~s({"error":"unauthorized"})
end

defmodule Apigw.Plugs.RateLimiter do
  @moduledoc """
  Plug enforcing per-principal request rate limits using a sliding window.
  Reads the principal set by `BearerAuth` and applies configurable limits.
  Returns a 429 response with Retry-After header when the limit is exceeded.
  """

  import Plug.Conn

  alias Apigw.RateLimit.WindowStore

  @behaviour Plug

  @type opts :: [max_requests: pos_integer(), window_seconds: pos_integer()]

  @impl Plug
  @spec init(opts()) :: opts()
  def init(opts) do
    Keyword.validate!(opts, max_requests: 100, window_seconds: 60)
  end

  @impl Plug
  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    max_requests = Keyword.fetch!(opts, :max_requests)
    window_seconds = Keyword.fetch!(opts, :window_seconds)

    case conn.assigns[:current_principal] do
      nil ->
        conn

      %{id: principal_id} ->
        check_limit(conn, principal_id, max_requests, window_seconds)
    end
  end

  @spec check_limit(Plug.Conn.t(), String.t(), pos_integer(), pos_integer()) :: Plug.Conn.t()
  defp check_limit(conn, principal_id, max_requests, window_seconds) do
    case WindowStore.increment(principal_id, window_seconds) do
      {:ok, count} when count <= max_requests ->
        put_resp_header(conn, "x-ratelimit-remaining", to_string(max_requests - count))

      {:ok, _count} ->
        conn
        |> put_resp_header("retry-after", to_string(window_seconds))
        |> put_resp_content_type("application/json")
        |> send_resp(429, ~s({"error":"rate_limit_exceeded"}))
        |> halt()

      {:error, _reason} ->
        conn
    end
  end
end
```
