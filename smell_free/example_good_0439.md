```elixir
defmodule MyAppWeb.Plug.CanaryRouter do
  @moduledoc """
  Routes a configurable percentage of inbound traffic to a canary backend
  for shadow testing or gradual feature rollouts. Routing is deterministic
  per user — the same user always hits the same backend — so session state
  and cache locality are preserved. The canary percentage is read from the
  application config on every request so it can be tuned at runtime via
  `Application.put_env/3` without restarting the server.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @stable_backend :primary
  @canary_backend :canary

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    canary_pct = canary_percentage()
    user_key = extract_routing_key(conn)
    backend = select_backend(user_key, canary_pct)

    conn
    |> assign(:backend, backend)
    |> tag_request(backend, canary_pct)
  end

  @doc """
  Returns the backend atom (`:primary` or `:canary`) assigned to `conn`.
  Call after this plug has run in the pipeline.
  """
  @spec assigned_backend(Plug.Conn.t()) :: :primary | :canary
  def assigned_backend(%Plug.Conn{assigns: %{backend: backend}}), do: backend
  def assigned_backend(_conn), do: :primary

  @doc """
  Returns `true` if `conn` has been routed to the canary backend.
  """
  @spec canary?(Plug.Conn.t()) :: boolean()
  def canary?(conn), do: assigned_backend(conn) == @canary_backend

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp select_backend(_key, 0), do: @stable_backend
  defp select_backend(_key, 100), do: @canary_backend

  defp select_backend(key, canary_pct) when is_integer(canary_pct) and canary_pct > 0 do
    bucket = :erlang.phash2(key, 100)
    if bucket < canary_pct, do: @canary_backend, else: @stable_backend
  end

  defp extract_routing_key(conn) do
    case get_session_user_id(conn) do
      nil -> ip_routing_key(conn)
      user_id -> user_id
    end
  end

  defp get_session_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp ip_routing_key(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp tag_request(conn, backend, pct) do
    conn
    |> put_resp_header("x-served-by", to_string(backend))
    |> put_resp_header("x-canary-pct", to_string(pct))
    |> log_routing(backend)
  end

  defp log_routing(conn, backend) do
    if backend == @canary_backend do
      Logger.debug("Request routed to canary backend",
        path: conn.request_path,
        routing_key: extract_routing_key(conn)
      )
    end

    conn
  end

  defp canary_percentage do
    :my_app
    |> Application.get_env(:canary_percentage, 0)
    |> clamp(0, 100)
  end

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
```
