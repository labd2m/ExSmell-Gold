```elixir
defmodule MyAppWeb.Plugs.BearerAuth do
  @behaviour Plug

  import Plug.Conn

  alias MyApp.Accounts
  alias MyApp.Tokens

  @moduledoc """
  A `Plug` that enforces Bearer token authentication on protected routes.
  Resolves the caller's identity and assigns it to `conn.assigns.current_user`.
  Returns a 401 JSON response if the token is missing, malformed, or expired.
  """

  @type options :: %{required(:realm) => String.t()}

  @impl Plug
  @spec init(keyword()) :: options()
  def init(opts) do
    realm = Keyword.get(opts, :realm, "Protected")
    %{realm: realm}
  end

  @impl Plug
  @spec call(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def call(conn, %{realm: realm}) do
    with {:ok, raw_token} <- extract_token(conn),
         {:ok, claims} <- Tokens.verify(raw_token),
         {:ok, user} <- Accounts.get_user(claims.sub) do
      assign(conn, :current_user, user)
    else
      {:error, :missing_token} -> halt_unauthorized(conn, realm, "Bearer token required.")
      {:error, :expired_token} -> halt_unauthorized(conn, realm, "Token has expired.")
      {:error, :invalid_token} -> halt_unauthorized(conn, realm, "Token is invalid.")
      {:error, :not_found} -> halt_unauthorized(conn, realm, "User account not found.")
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp halt_unauthorized(conn, realm, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("www-authenticate", ~s(Bearer realm="#{realm}"))
    |> send_resp(401, body)
    |> halt()
  end
end

defmodule MyApp.Tokens do
  @moduledoc """
  Issues and verifies signed JWT tokens backed by a configurable secret.
  Accepts configuration via direct argument to avoid compile-time global coupling.
  """

  @type claims :: %{sub: String.t(), exp: integer()}

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(subject, opts \\ []) when is_binary(subject) do
    ttl_seconds = Keyword.get(opts, :ttl, 3600)
    secret = Keyword.fetch!(opts, :secret)
    exp = System.system_time(:second) + ttl_seconds

    JOSE.JWT.sign(
      JOSE.JWK.from_oct(secret),
      %{"sub" => subject, "exp" => exp}
    )
    |> JOSE.JWS.compact()
    |> then(fn {_, token} -> {:ok, token} end)
  rescue
    exception -> {:error, exception}
  end

  @spec verify(String.t(), keyword()) :: {:ok, claims()} | {:error, :invalid_token | :expired_token}
  def verify(token, opts \\ []) when is_binary(token) do
    secret = Keyword.fetch!(opts, :secret)
    now = System.system_time(:second)

    with {true, %{fields: fields}, _} <-
           JOSE.JWT.verify_strict(JOSE.JWK.from_oct(secret), ["HS256"], token),
         %{"sub" => sub, "exp" => exp} <- fields,
         true <- exp > now do
      {:ok, %{sub: sub, exp: exp}}
    else
      {false, _, _} -> {:error, :invalid_token}
      false -> {:error, :expired_token}
      _ -> {:error, :invalid_token}
    end
  end
end
```
