```elixir
defmodule ApiGateway.Plugs.BearerAuth do
  @moduledoc """
  Plug that authenticates inbound requests using Bearer tokens.

  The plug extracts the Authorization header, verifies the token against
  the session store, and assigns the resolved session to the connection.
  Requests carrying missing, malformed, expired, or unknown tokens are
  halted with a structured 401 JSON response before reaching downstream
  handlers.

  Paths listed under the `:exclude_paths` option bypass authentication
  entirely, which is appropriate for public endpoints such as health
  checks and login routes.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias ApiGateway.Sessions
  alias ApiGateway.Sessions.Session

  @type opts :: [exclude_paths: [String.t()]]

  @impl Plug
  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    excluded = Keyword.get(opts, :exclude_paths, [])

    if conn.request_path in excluded do
      conn
    else
      authenticate(conn)
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp authenticate(conn) do
    conn
    |> extract_token()
    |> resolve_session(conn)
  end

  defp extract_token(conn) do
    conn
    |> get_req_header("authorization")
    |> parse_authorization_header()
  end

  defp parse_authorization_header(["Bearer " <> raw | _]) do
    token = String.trim(raw)
    if byte_size(token) > 0, do: {:ok, token}, else: {:error, :empty_token}
  end

  defp parse_authorization_header(_), do: {:error, :missing_token}

  defp resolve_session({:error, reason}, conn) do
    log_rejection(conn, reason)
    halt_unauthorized(conn, rejection_message(reason))
  end

  defp resolve_session({:ok, token}, conn) do
    case Sessions.fetch_by_token(token) do
      {:ok, %Session{} = session} ->
        assign(conn, :current_session, session)

      {:error, :expired} ->
        log_rejection(conn, :expired_token)
        halt_unauthorized(conn, "Authentication token has expired")

      {:error, :not_found} ->
        log_rejection(conn, :invalid_token)
        halt_unauthorized(conn, "Authentication token is invalid")
    end
  end

  defp halt_unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", detail: message})
    |> halt()
  end

  defp rejection_message(:missing_token), do: "Authorization header with Bearer token is required"
  defp rejection_message(:empty_token), do: "Bearer token value must not be empty"
  defp rejection_message(_), do: "Authentication failed"

  defp log_rejection(conn, reason) do
    Logger.warning("Request rejected at auth plug",
      path: conn.request_path,
      remote_ip: format_ip(conn.remote_ip),
      reason: reason
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> Tuple.to_list() |> Enum.join(".")
  defp format_ip(_), do: "unknown"
end
```
