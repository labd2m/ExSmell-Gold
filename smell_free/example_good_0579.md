```elixir
defmodule AppWeb.Plugs.CsrfProtection do
  @moduledoc """
  A Plug that enforces CSRF protection for state-mutating HTTP methods.

  A per-session CSRF token is generated on first request and stored in
  a signed cookie. Mutating requests (POST, PUT, PATCH, DELETE) must echo
  the token in the `X-CSRF-Token` header or the `_csrf_token` form field.
  Verification is constant-time to prevent timing attacks.
  """

  import Plug.Conn

  @behaviour Plug

  @cookie_name "_csrf_token"
  @header_name "x-csrf-token"
  @form_field "_csrf_token"
  @safe_methods ~w[GET HEAD OPTIONS TRACE]
  @token_bytes 32
  @cookie_opts [http_only: true, same_site: "Strict", secure: true, max_age: 86_400]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> ensure_token(opts)
    |> verify_if_mutating()
  end

  @doc "Returns the current CSRF token for embedding in forms or SPA state."
  @spec token(Plug.Conn.t()) :: String.t() | nil
  def token(conn), do: conn.assigns[:csrf_token]

  defp ensure_token(conn, opts) do
    case fetch_existing_token(conn) do
      {:ok, token} ->
        assign(conn, :csrf_token, token)

      :missing ->
        token = generate_token()
        secure = Keyword.get(opts, :secure, true)
        cookie_opts = Keyword.merge(@cookie_opts, secure: secure)

        conn
        |> put_resp_cookie(@cookie_name, token, cookie_opts)
        |> assign(:csrf_token, token)
    end
  end

  defp fetch_existing_token(conn) do
    conn = fetch_cookies(conn, signed: [@cookie_name])

    case conn.cookies[@cookie_name] do
      nil -> :missing
      token when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _ -> :missing
    end
  end

  defp verify_if_mutating(%{method: method} = conn) when method in @safe_methods, do: conn

  defp verify_if_mutating(conn) do
    server_token = conn.assigns[:csrf_token]
    client_token = extract_client_token(conn)

    if client_token && Plug.Crypto.secure_compare(server_token, client_token) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "invalid_csrf_token"}))
      |> halt()
    end
  end

  defp extract_client_token(conn) do
    header_token = conn |> get_req_header(@header_name) |> List.first()

    if header_token do
      header_token
    else
      conn = fetch_body_params(conn)
      Map.get(conn.body_params, @form_field)
    end
  end

  defp fetch_body_params(conn) do
    case Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded, :multipart])) do
      conn -> conn
    end
  rescue
    _ -> conn
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end
end
```
