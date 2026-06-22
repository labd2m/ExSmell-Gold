```elixir
defmodule Auth.Plug.VerifyToken do
  @moduledoc """
  A Plug that authenticates requests by verifying a Bearer token from
  the Authorization header. On success, decoded claims are assigned to
  the connection. On failure, the connection is halted with a 401 response.
  """

  import Plug.Conn

  alias Auth.TokenVerifier

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> extract_bearer()
    |> TokenVerifier.verify()
    |> apply_result(conn)
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp apply_result({:ok, claims}, conn), do: assign(conn, :current_claims, claims)

  defp apply_result({:error, reason}, conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, error_body(reason))
    |> halt()
  end

  defp error_body(:missing_token), do: ~s({"error":"missing_token"})
  defp error_body(:token_expired), do: ~s({"error":"token_expired"})
  defp error_body(_), do: ~s({"error":"invalid_token"})
end

defmodule Auth.TokenVerifier do
  @moduledoc """
  Verifies signed tokens and decodes their claims payload.
  The signing secret is accepted as a runtime argument to allow
  multi-tenant or per-environment configurations.
  """

  @type claims :: %{String.t() => term()}
  @type verify_result :: {:ok, claims()} | {:error, atom()}

  @spec verify(String.t() | {:error, atom()}, keyword()) :: verify_result()
  def verify({:error, _} = err, _opts \\ []), do: err

  def verify({:ok, raw_token}, opts), do: verify(raw_token, opts)

  def verify(raw_token, opts) when is_binary(raw_token) do
    secret = Keyword.get(opts, :secret, fetch_default_secret())

    with {:ok, {payload, sig}} <- split_token(raw_token),
         :ok <- verify_signature(payload, sig, secret),
         {:ok, claims} <- decode_payload(payload),
         :ok <- check_expiry(claims) do
      {:ok, claims}
    end
  end

  defp split_token(token) do
    case String.split(token, ".", parts: 2) do
      [payload, sig] -> {:ok, {payload, sig}}
      _ -> {:error, :malformed_token}
    end
  end

  defp verify_signature(payload, sig, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp decode_payload(payload) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :malformed_payload}
    end
  end

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :token_expired}
  end

  defp check_expiry(_), do: {:error, :missing_expiry}

  defp fetch_default_secret do
    Application.get_env(:auth, :token_secret, "insecure-dev-secret")
  end
end
```
