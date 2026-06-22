```elixir
defmodule MyApp.Accounts.ImpersonationGuard do
  @moduledoc """
  A Plug that detects an active impersonation session from the request
  and populates both `:current_user` (the impersonated user) and
  `:acting_as` (the admin performing the impersonation) in conn assigns.
  When no impersonation token is present the plug is a no-op so it can
  be placed in a shared pipeline without affecting normal sessions.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.Accounts.ImpersonationSession

  @impersonation_header "x-impersonation-token"
  @cookie_key "imp_token"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case extract_token(conn) do
      nil -> conn
      token -> apply_impersonation(conn, token)
    end
  end

  @spec extract_token(Plug.Conn.t()) :: String.t() | nil
  defp extract_token(conn) do
    header_token(conn) || cookie_token(conn)
  end

  @spec header_token(Plug.Conn.t()) :: String.t() | nil
  defp header_token(conn) do
    case get_req_header(conn, @impersonation_header) do
      [token | _] when is_binary(token) and byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  @spec cookie_token(Plug.Conn.t()) :: String.t() | nil
  defp cookie_token(conn) do
    conn = fetch_cookies(conn)
    Map.get(conn.cookies, @cookie_key)
  end

  @spec apply_impersonation(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp apply_impersonation(conn, token) do
    case ImpersonationSession.verify(token) do
      {:ok, {admin_id, target_user}} ->
        conn
        |> assign(:current_user, target_user)
        |> assign(:acting_as, %{admin_id: admin_id, impersonating: true})
        |> put_private(:impersonation_token, token)

      {:error, :invalid} ->
        conn
        |> delete_resp_cookie(@cookie_key)
    end
  end
end
```
