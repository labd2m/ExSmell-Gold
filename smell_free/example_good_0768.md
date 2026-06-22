```elixir
defmodule Platform.FeatureFlagPlug do
  @moduledoc """
  Enforces feature flag gating at the HTTP layer. When a flagged feature
  is disabled, the plug responds with a 404 or 503 depending on the
  configured `on_disabled` behaviour. Feature flag state is read from
  `Platform.FeatureRegistry` so the plug reflects runtime changes without
  redeployment or connection restart.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    %{
      flag: Keyword.fetch!(opts, :flag),
      on_disabled: Keyword.get(opts, :on_disabled, :not_found)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %{flag: flag, on_disabled: on_disabled}) do
    if Platform.FeatureRegistry.enabled?(flag) do
      conn
    else
      handle_disabled(conn, on_disabled)
    end
  end

  defp handle_disabled(conn, :not_found) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
    |> halt()
  end

  defp handle_disabled(conn, :service_unavailable) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "feature_disabled"}))
    |> halt()
  end

  defp handle_disabled(conn, {:redirect, path}) when is_binary(path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(302, "")
    |> halt()
  end
end
```
