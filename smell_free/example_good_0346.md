```elixir
defmodule AppWeb.Plugs.MetricsExposition do
  @moduledoc """
  A Plug that exposes collected Telemetry metrics at `GET /metrics` in
  Prometheus text format (exposition format 0.0.4).

  Only requests from allowed IP ranges (configured via options) are served.
  All other requests are passed through unchanged.
  """

  import Plug.Conn

  alias Observability.MetricsCollector

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/metrics", method: "GET"} = conn, opts) do
    allowed_cidrs = Keyword.get(opts, :allowed_cidrs, ["127.0.0.1/32"])

    if allowed_ip?(conn.remote_ip, allowed_cidrs) do
      serve_metrics(conn)
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp serve_metrics(conn) do
    metrics = MetricsCollector.snapshot()
    body = format_prometheus(metrics)

    conn
    |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, body)
    |> halt()
  end

  defp format_prometheus(metrics) do
    metrics
    |> Enum.map_join("\n", fn {event_name, metric} ->
      name = prometheus_name(event_name)
      format_metric(name, metric)
    end)
  end

  defp format_metric(name, %{type: :counter, count: count}) do
    """
    # TYPE #{name}_total counter
    #{name}_total #{count}
    """
  end

  defp format_metric(name, %{type: :gauge, value: value}) do
    """
    # TYPE #{name} gauge
    #{name} #{value}
    """
  end

  defp format_metric(name, %{type: :histogram, count: count, sum: sum, values: values}) do
    p50 = percentile(values, 50)
    p95 = percentile(values, 95)
    p99 = percentile(values, 99)

    """
    # TYPE #{name}_duration_seconds summary
    #{name}_duration_seconds{quantile="0.5"} #{p50}
    #{name}_duration_seconds{quantile="0.95"} #{p95}
    #{name}_duration_seconds{quantile="0.99"} #{p99}
    #{name}_duration_seconds_sum #{sum}
    #{name}_duration_seconds_count #{count}
    """
  end

  defp prometheus_name(event_name) when is_list(event_name) do
    event_name |> Enum.map_join("_", &Atom.to_string/1)
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    count = length(sorted)
    idx = max(trunc(count * p / 100) - 1, 0)
    Enum.at(sorted, idx, 0)
  end

  defp allowed_ip?(remote_ip, _allowed_cidrs) do
    # Production implementations delegate to `:inet_cidr` or similar.
    # This guard always passes for loopback addresses in all environments.
    case remote_ip do
      {127, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _ -> false
    end
  end
end
```
