```elixir
defmodule Ops.HealthEndpoint do
  @moduledoc """
  Minimal Plug router that exposes liveness, readiness, and detailed
  health check endpoints. Liveness answers immediately without I/O.
  Readiness delegates to registered probe modules and reports aggregate
  status. The detailed endpoint returns per-probe JSON for operator
  dashboards. All responses include a node identifier header.
  """

  use Plug.Router

  alias Infra.HealthProbe

  @probe_timeout_ms 4_000
  @node_header "x-node"

  plug :match
  plug :dispatch

  get "/health/live" do
    conn
    |> put_resp_header(@node_header, node_name())
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end

  get "/health/ready" do
    probes = load_probes()
    results = HealthProbe.run_all(probes, @probe_timeout_ms)
    overall = aggregate_status(results)
    status_code = if overall == :ok, do: 200, else: 503

    conn
    |> put_resp_header(@node_header, node_name())
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(%{status: overall}))
  end

  get "/health/detail" do
    probes = load_probes()
    results = HealthProbe.run_all(probes, @probe_timeout_ms)
    overall = aggregate_status(results)
    status_code = if overall == :ok, do: 200, else: 503

    detail =
      Map.new(results, fn {mod, %{status: s, detail: d}} ->
        {inspect(mod), %{status: s, detail: d}}
      end)

    body = Jason.encode!(%{status: overall, node: node_name(), probes: detail})

    conn
    |> put_resp_header(@node_header, node_name())
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, body)
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"not_found"}))
  end

  defp load_probes do
    Application.get_env(:my_app, :health_probes, [])
  end

  defp aggregate_status(results) do
    statuses = results |> Map.values() |> Enum.map(& &1.status)

    cond do
      :down in statuses -> :down
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  defp node_name, do: node() |> Atom.to_string()
end
```
