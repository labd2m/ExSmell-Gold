```elixir
defmodule Web.Plugs.BearerAuth do
  @moduledoc """
  A Plug that authenticates inbound HTTP requests by verifying a Bearer
  token in the Authorization header. On success it assigns the resolved
  principal to the connection; on failure it halts with a 401 response.
  """

  import Plug.Conn

  alias Auth.TokenRegistry
  alias Web.ErrorView

  @behaviour Plug

  @type opts :: [required_scopes: [String.t()], realm: String.t()]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    required_scopes = Keyword.get(opts, :required_scopes, [])

    conn
    |> extract_token()
    |> validate_token()
    |> check_scopes(required_scopes)
    |> apply_result(conn)
  end

  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_token}
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  @spec validate_token({:ok, String.t()} | {:error, atom()}) ::
          {:ok, map()} | {:error, :missing_token | :invalid_token | :expired_token}
  defp validate_token({:error, reason}), do: {:error, reason}

  defp validate_token({:ok, token}) do
    case TokenRegistry.validate(token) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :invalid_token}
      {:error, :expired} -> {:error, :expired_token}
    end
  end

  @spec check_scopes({:ok, map()} | {:error, atom()}, [String.t()]) ::
          {:ok, map()} | {:error, atom()}
  defp check_scopes({:error, reason}, _required), do: {:error, reason}
  defp check_scopes({:ok, entry}, []), do: {:ok, entry}

  defp check_scopes({:ok, entry}, required_scopes) do
    granted = MapSet.new(entry.scopes)
    required = MapSet.new(required_scopes)

    if MapSet.subset?(required, granted) do
      {:ok, entry}
    else
      {:error, :insufficient_scopes}
    end
  end

  @spec apply_result({:ok, map()} | {:error, atom()}, Plug.Conn.t()) :: Plug.Conn.t()
  defp apply_result({:ok, entry}, conn) do
    conn
    |> assign(:current_user_id, entry.user_id)
    |> assign(:token_scopes, entry.scopes)
  end

  defp apply_result({:error, reason}, conn) do
    body = Jason.encode!(%{error: error_message(reason)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  @spec error_message(atom()) :: String.t()
  defp error_message(:missing_token), do: "Authorization header is required"
  defp error_message(:invalid_token), do: "Token is invalid"
  defp error_message(:expired_token), do: "Token has expired"
  defp error_message(:insufficient_scopes), do: "Token lacks required permissions"
  defp error_message(_), do: "Authentication failed"
end
```
