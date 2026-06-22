```elixir
defmodule Platform.FeatureScopePlug do
  @moduledoc """
  Guards controller actions behind named feature scopes. Each scope
  maps to a set of required capabilities checked against the current
  tenant's active feature set. Requests that lack a required capability
  receive a 403 response with a structured error body. The plug reads
  capability state from `Platform.CapabilityRegistry` so changes to
  feature flags propagate immediately without restarting connections.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      required: Keyword.fetch!(opts, :requires),
      on_denied: Keyword.get(opts, :on_denied, :forbidden)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %{required: required, on_denied: on_denied}) do
    requirements = List.wrap(required)

    disabled = Enum.reject(requirements, &Platform.CapabilityRegistry.enabled?/1)

    if Enum.empty?(disabled) do
      conn
    else
      handle_denied(conn, disabled, on_denied)
    end
  end

  defp handle_denied(conn, missing_capabilities, :forbidden) do
    body =
      Jason.encode!(%{
        error: "capability_required",
        missing_capabilities: Enum.map(missing_capabilities, &Atom.to_string/1)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, body)
    |> halt()
  end

  defp handle_denied(conn, _missing, :not_found) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not_found"}))
    |> halt()
  end

  defp handle_denied(conn, _missing, {:redirect, path}) when is_binary(path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(302, "")
    |> halt()
  end
end
```
