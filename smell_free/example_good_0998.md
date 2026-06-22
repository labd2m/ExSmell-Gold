```elixir
defmodule MyApp.Infra.HealthEndpoint do
  @moduledoc """
  A minimal Plug router that exposes `/health/live` and `/health/ready`
  endpoints for orchestration systems such as Kubernetes. Liveness
  responds immediately with `200` as long as the VM is running. Readiness
  delegates to `MyApp.Observability.HealthChecker` and returns `503`
  when any registered check is failing.

  Mount directly in the Phoenix endpoint config or as a standalone Cowboy
  handler for pre-boot health checks before the full Phoenix app starts.
  """

  use Plug.Router

  alias MyApp.Observability.HealthChecker

  plug :match
  plug :dispatch

  get "/health/live" do
    send_resp(conn, 200, ~s({"status":"ok"}))
  end

  get "/health/ready" do
    result = HealthChecker.check(:readiness)

    {status, body} =
      case result.status do
        :ok ->
          {200, encode_health(result)}

        :degraded ->
          {503, encode_health(result)}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"not_found"}))
  end

  @spec encode_health(map()) :: String.t()
  defp encode_health(result) do
    checks =
      Map.new(result.checks, fn check ->
        {check.name, %{status: check.status, detail: check.detail}}
      end)

    Jason.encode!(%{status: result.status, checks: checks})
  end
end
```
