```elixir
defmodule Platform.SignedCookieSession do
  @moduledoc """
  Manages server-side sessions backed by signed cookies. The session ID
  is stored in a cookie; session data lives in the database keyed by that
  ID. Cookie integrity is verified on every request using HMAC-SHA256
  so tampered or forged cookies are rejected immediately without a
  database lookup.
  """

  import Plug.Conn

  alias Sessions.Store

  @cookie_name "_session_id"
  @hmac_algo :sha256
  @id_bytes 24

  @doc "Reads the session from the cookie and assigns data to the connection."
  @spec load(Plug.Conn.t()) :: Plug.Conn.t()
  def load(%Plug.Conn{} = conn) do
    case read_cookie(conn) do
      {:ok, session_id} ->
        case Store.fetch(session_id) do
          {:ok, data} ->
            conn
            |> assign(:session_id, session_id)
            |> assign(:session, data)

          {:error, _} ->
            conn
            |> assign(:session_id, nil)
            |> assign(:session, %{})
        end

      :error ->
        conn
        |> assign(:session_id, nil)
        |> assign(:session, %{})
    end
  end

  @doc "Persists session data and writes the signed cookie to the response."
  @spec persist(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def persist(%Plug.Conn{} = conn, data) when is_map(data) do
    session_id =
      conn.assigns[:session_id] ||
        (:crypto.strong_rand_bytes(@id_bytes) |> Base.url_encode64(padding: false))

    Store.update(session_id, data)
    signed = sign(session_id)

    put_resp_cookie(conn, @cookie_name, signed,
      http_only: true,
      secure: true,
      same_site: "Lax",
      max_age: 86_400 * 30
    )
  end

  @doc "Invalidates the current session and clears the cookie."
  @spec invalidate(Plug.Conn.t()) :: Plug.Conn.t()
  def invalidate(%Plug.Conn{} = conn) do
    if session_id = conn.assigns[:session_id] do
      Store.invalidate(session_id)
    end

    delete_resp_cookie(conn, @cookie_name)
  end

  defp read_cookie(conn) do
    conn = Plug.Conn.fetch_cookies(conn)

    case Map.get(conn.cookies, @cookie_name) do
      nil -> :error
      raw -> verify(raw)
    end
  end

  defp sign(session_id) do
    sig = :crypto.mac(:hmac, @hmac_algo, secret(), session_id) |> Base.url_encode64(padding: false)
    "#{session_id}.#{sig}"
  end

  defp verify(raw) do
    case String.split(raw, ".", parts: 2) do
      [session_id, provided_sig] ->
        expected_sig =
          :crypto.mac(:hmac, @hmac_algo, secret(), session_id) |> Base.url_encode64(padding: false)

        if secure_compare(provided_sig, expected_sig), do: {:ok, session_id}, else: :error

      _ ->
        :error
    end
  end

  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false
  defp secure_compare(a, b), do: :crypto.hash_equals(a, b)

  defp secret, do: Application.fetch_env!(:my_app, :session_secret)
end
```
