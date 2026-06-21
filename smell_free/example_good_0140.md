```elixir
defmodule MyApp.Plug.RequireAuth do
  @moduledoc """
  A Plug that enforces JWT bearer authentication on protected routes.
  If the `Authorization` header contains a valid access token the owning
  user is assigned to `conn.assigns.current_user` and the request proceeds.

  On failure the plug halts the connection and renders a machine-readable
  JSON error so that API clients receive a consistent error shape regardless
  of where in the router the plug is mounted.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.Auth.Guardian

  @bearer_prefix "Bearer "

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> extract_token()
    |> verify_token()
    |> apply_result(conn)
  end

  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_token}
  defp extract_token(conn) do
    conn
    |> get_req_header("authorization")
    |> pick_bearer()
  end

  @spec pick_bearer([String.t()]) :: {:ok, String.t()} | {:error, :missing_token}
  defp pick_bearer([header | _]) when is_binary(header) do
    if String.starts_with?(header, @bearer_prefix) do
      {:ok, String.slice(header, byte_size(@bearer_prefix)..-1//1)}
    else
      {:error, :missing_token}
    end
  end

  defp pick_bearer(_), do: {:error, :missing_token}

  @spec verify_token({:ok, String.t()} | {:error, term()}) ::
          {:ok, MyApp.Accounts.User.t()} | {:error, term()}
  defp verify_token({:ok, token}), do: Guardian.verify_access(token)
  defp verify_token({:error, _} = err), do: err

  @spec apply_result(
          {:ok, MyApp.Accounts.User.t()} | {:error, term()},
          Plug.Conn.t()
        ) :: Plug.Conn.t()
  defp apply_result({:ok, user}, conn) do
    assign(conn, :current_user, user)
  end

  defp apply_result({:error, reason}, conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, encode_error(reason))
    |> halt()
  end

  @spec encode_error(term()) :: String.t()
  defp encode_error(:missing_token) do
    Jason.encode!(%{error: %{code: "missing_token", message: "Authorization header is required"}})
  end

  defp encode_error(:wrong_token_type) do
    Jason.encode!(%{error: %{code: "wrong_token_type", message: "A bearer access token is required"}})
  end

  defp encode_error(_reason) do
    Jason.encode!(%{error: %{code: "invalid_token", message: "The provided token is invalid or expired"}})
  end
end
```
