**File:** `example_good_1377.md`

```elixir
defmodule Auth.Token do
  @moduledoc """
  Handles creation and verification of signed JWT-style bearer tokens
  using HMAC-SHA256 with a configurable secret.
  """

  @type claims :: %{sub: String.t(), role: String.t(), exp: integer()}
  @type verify_result :: {:ok, claims()} | {:error, :expired} | {:error, :invalid}

  @spec generate(claims(), String.t()) :: String.t()
  def generate(claims, secret) when is_map(claims) and is_binary(secret) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    sig = compute_signature(payload, secret)
    "#{payload}.#{sig}"
  end

  @spec verify(String.t(), String.t()) :: verify_result()
  def verify(token, secret) when is_binary(token) and is_binary(secret) do
    with [payload, provided_sig] <- String.split(token, "."),
         ^provided_sig <- compute_signature(payload, secret),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json, keys: :atoms),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    else
      :expired -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end

  defp compute_signature(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp check_expiry(%{exp: exp}) when is_integer(exp) do
    now = System.system_time(:second)
    if exp > now, do: :ok, else: :expired
  end

  defp check_expiry(_claims), do: :ok
end

defmodule Auth.CurrentUser do
  @moduledoc "Struct representing an authenticated user attached to a connection."

  @enforce_keys [:id, :role]
  defstruct [:id, :role]

  @type t :: %__MODULE__{
          id: String.t(),
          role: String.t()
        }
end

defmodule Auth.BearerPlug do
  @moduledoc """
  A Plug that extracts and verifies a Bearer token from the Authorization header.
  Assigns the verified user to the connection or halts with 401.
  """

  import Plug.Conn

  alias Auth.{Token, CurrentUser}

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    secret = Keyword.fetch!(opts, :secret)

    conn
    |> extract_bearer_token()
    |> verify_token(secret)
    |> handle_result(conn)
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp verify_token({:ok, token}, secret), do: Token.verify(token, secret)
  defp verify_token({:error, reason}, _secret), do: {:error, reason}

  defp handle_result({:ok, %{sub: id, role: role}}, conn) do
    assign(conn, :current_user, %CurrentUser{id: id, role: role})
  end

  defp handle_result({:error, :expired}, conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "token_expired"}))
    |> halt()
  end

  defp handle_result({:error, _}, conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end

defmodule Auth.RequireRolePlug do
  @moduledoc """
  A Plug that enforces a minimum role requirement on an authenticated connection.
  Must be placed after `Auth.BearerPlug` in the pipeline.
  """

  import Plug.Conn

  alias Auth.CurrentUser

  @role_hierarchy ~w(viewer member admin)

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    required = Keyword.fetch!(opts, :role)
    user = conn.assigns[:current_user]

    if authorized?(user, required) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
      |> halt()
    end
  end

  defp authorized?(%CurrentUser{role: role}, required) do
    role_rank(role) >= role_rank(required)
  end

  defp authorized?(nil, _required), do: false

  defp role_rank(role), do: Enum.find_index(@role_hierarchy, &(&1 == role)) || -1
end
```
