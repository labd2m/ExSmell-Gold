```elixir
defmodule AppWeb.Plugs.SessionFixationProtection do
  @moduledoc """
  A Plug that regenerates the session identifier upon privilege escalation
  to prevent session fixation attacks.

  Session regeneration is triggered by calling `rotate_session/1` after
  authentication completes. The existing session data is preserved and
  migrated to the new session, while the old session is invalidated.
  """

  import Plug.Conn

  @behaviour Plug

  @rotation_key :__session_rotated__
  @rotation_marker :__rotate_session__

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> fetch_session()
    |> check_rotation_marker()
  end

  @doc """
  Marks the session for rotation. The actual rotation happens on the next
  `call/2` invocation or when the response is sent via `register_before_send`.

  Call this immediately after verifying user credentials.
  """
  @spec rotate_session(Plug.Conn.t()) :: Plug.Conn.t()
  def rotate_session(conn) do
    conn
    |> put_session(@rotation_marker, true)
    |> register_before_send(&perform_rotation/1)
  end

  @doc "Returns `true` if the session was rotated during the current request."
  @spec rotated?(Plug.Conn.t()) :: boolean()
  def rotated?(conn), do: conn.assigns[@rotation_key] == true

  defp check_rotation_marker(conn) do
    if get_session(conn, @rotation_marker) do
      perform_rotation(conn)
    else
      conn
    end
  end

  defp perform_rotation(conn) do
    session_data =
      conn
      |> get_session()
      |> Map.delete(Atom.to_string(@rotation_marker))
      |> Map.delete(@rotation_marker)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> restore_session_data(session_data)
    |> assign(@rotation_key, true)
  end

  defp restore_session_data(conn, session_data) do
    Enum.reduce(session_data, conn, fn {key, value}, acc ->
      put_session(acc, key, value)
    end)
  end
end

defmodule AppWeb.Plugs.SessionExpiry do
  @moduledoc """
  A Plug that enforces absolute and idle session expiry times.

  Two complementary timeouts are enforced:
  - Absolute TTL: the session is always invalidated after `max_age_seconds`.
  - Idle TTL: the session is invalidated after `idle_timeout_seconds` of inactivity.
  """

  import Plug.Conn

  @behaviour Plug

  @created_at_key :__session_created_at__
  @last_seen_key :__session_last_seen__

  @impl Plug
  def init(opts) do
    %{
      max_age_seconds: Keyword.get(opts, :max_age_seconds, 86_400),
      idle_timeout_seconds: Keyword.get(opts, :idle_timeout_seconds, 3_600)
    }
  end

  @impl Plug
  def call(conn, %{max_age_seconds: max_age, idle_timeout_seconds: idle_timeout}) do
    conn = fetch_session(conn)
    now = System.os_time(:second)

    cond do
      absolute_expired?(conn, now, max_age) -> invalidate_session(conn)
      idle_expired?(conn, now, idle_timeout) -> invalidate_session(conn)
      true -> touch_session(conn, now)
    end
  end

  defp absolute_expired?(conn, now, max_age) do
    case get_session(conn, @created_at_key) do
      nil -> false
      created_at -> now - created_at > max_age
    end
  end

  defp idle_expired?(conn, now, idle_timeout) do
    case get_session(conn, @last_seen_key) do
      nil -> false
      last_seen -> now - last_seen > idle_timeout
    end
  end

  defp invalidate_session(conn) do
    conn
    |> configure_session(drop: true)
    |> assign(:session_expired, true)
  end

  defp touch_session(conn, now) do
    conn
    |> put_session(@created_at_key, get_session(conn, @created_at_key) || now)
    |> put_session(@last_seen_key, now)
  end
end
```
