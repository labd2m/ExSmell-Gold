```elixir
defmodule Storefront.Plugs.AuthenticateRequest do
  @moduledoc """
  A Plug that authenticates incoming HTTP requests via a Bearer token.

  On success, assigns the verified `%Account{}` struct to
  `conn.assigns.current_account`. On failure, halts the connection with
  a JSON error body and the appropriate HTTP status.

  Specific request paths can be exempted from authentication via the
  `bypass_paths` option.
  """

  import Plug.Conn

  alias Storefront.Auth.TokenVerifier
  alias Storefront.Accounts

  @behaviour Plug

  @type opt :: {:bypass_paths, [String.t()]}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    bypass_paths = Keyword.get(opts, :bypass_paths, [])

    if bypassed?(conn.request_path, bypass_paths) do
      conn
    else
      authenticate(conn)
    end
  end

  defp authenticate(conn) do
    conn
    |> extract_bearer_token()
    |> verify_token()
    |> load_account()
    |> finalize(conn)
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp verify_token({:error, _} = err), do: err

  defp verify_token({:ok, token}) do
    case TokenVerifier.verify(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_account({:error, _} = err), do: err

  defp load_account({:ok, %{account_id: account_id}}) do
    case Accounts.fetch(account_id) do
      {:ok, account} -> {:ok, account}
      {:error, :not_found} -> {:error, :account_not_found}
    end
  end

  defp finalize({:ok, account}, conn) do
    assign(conn, :current_account, account)
  end

  defp finalize({:error, reason}, conn) do
    status = http_status(reason)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, encode_error(reason))
    |> halt()
  end

  defp http_status(:missing_token), do: 401
  defp http_status(:expired_token), do: 401
  defp http_status(:invalid_token), do: 401
  defp http_status(:account_not_found), do: 403
  defp http_status(_), do: 401

  defp encode_error(reason) do
    Jason.encode!(%{error: Atom.to_string(reason)})
  end

  defp bypassed?(path, bypass_paths) do
    Enum.any?(bypass_paths, &String.starts_with?(path, &1))
  end
end
```
