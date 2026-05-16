```elixir
defmodule Reports.MetricsFetcher do
  @moduledoc """
  Fetches aggregated metrics from the analytics platform API and stores
  normalised report data for dashboard consumption.
  """

  require Logger

  alias Reports.{MetricSnapshot, Dashboard, ReportCache}
  alias Reports.Repo

  @fetch_timeout 20_000
  @cache_ttl_seconds 3_600

  def fetch_dashboard_metrics(dashboard_id, date_range) do
    with {:ok, dashboard} <- Dashboard.fetch(dashboard_id),
         :ok <- validate_date_range(date_range),
         {:ok, raw} <- request_metrics(dashboard, date_range) do
      store_snapshot(dashboard_id, date_range, raw)
    end
  end

  def get_cached_or_fetch(dashboard_id, date_range) do
    cache_key = build_cache_key(dashboard_id, date_range)

    case ReportCache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        with {:ok, snapshot} <- fetch_dashboard_metrics(dashboard_id, date_range) do
          ReportCache.put(cache_key, snapshot, ttl: @cache_ttl_seconds)
          {:ok, snapshot}
        end
    end
  end

  def list_available_metrics(workspace_id) do
    case AnalyticsPlatform.list_metrics(workspace_id) do
      {:ok, metrics} -> {:ok, Enum.map(metrics, &format_metric_descriptor/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_date_range(%{from: from, to: to}) do
    cond do
      Date.compare(from, to) == :gt -> {:error, :invalid_range}
      Date.diff(to, from) > 365 -> {:error, :range_too_large}
      true -> :ok
    end
  end

  defp request_metrics(%Dashboard{workspace_id: ws_id, metric_ids: metric_ids}, date_range) do
    params = %{
      workspace_id: ws_id,
      metrics: metric_ids,
      from: Date.to_iso8601(date_range.from),
      to: Date.to_iso8601(date_range.to),
      granularity: date_range[:granularity] || "day"
    }

    AnalyticsPlatform.fetch_metrics(params, timeout: @fetch_timeout)
    |> parse_metrics_response()
  end

  defp parse_metrics_response(response) do
    case response do
      {:ok, %{status: 200, body: %{"data" => data, "meta" => meta}}} ->
        {:ok, %{data: normalize_data_points(data), meta: meta}}

      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, %{data: normalize_data_points(data), meta: %{}}}

      {:ok, %{status: 204}} ->
        Logger.info("Analytics platform returned no data for the requested range")
        {:ok, %{data: [], meta: %{}}}

      {:ok, %{status: 400, body: %{"error" => "invalid_metric_id", "details" => ids}}} ->
        Logger.warning("Unknown metric IDs requested: #{inspect(ids)}")
        {:error, {:invalid_metrics, ids}}

      {:ok, %{status: 400, body: %{"error" => "invalid_date_range", "message" => msg}}} ->
        {:error, {:invalid_date_range, msg}}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        {:error, {:bad_request, msg}}

      {:ok, %{status: 401}} ->
        Logger.error("Analytics platform API key is invalid or expired")
        {:error, :unauthorized}

      {:ok, %{status: 403, body: %{"error" => "workspace_suspended"}}} ->
        Logger.warning("Analytics workspace has been suspended")
        {:error, :workspace_suspended}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :workspace_not_found}

      {:ok, %{status: 422, body: %{"errors" => errors}}} ->
        {:error, {:validation_errors, errors}}

      {:ok, %{status: 429, headers: headers}} ->
        reset_at = get_rate_limit_reset(headers)
        Logger.warning("Analytics API rate limit exceeded, resets at #{reset_at}")
        {:error, {:rate_limited, reset_at}}

      {:ok, %{status: 500}} ->
        Logger.error("Analytics platform returned internal server error")
        {:error, :platform_error}

      {:ok, %{status: 503, headers: headers}} ->
        retry_after = get_retry_after(headers)
        {:error, {:service_unavailable, retry_after}}

      {:ok, %{status: status}} ->
        Logger.error("Unhandled analytics platform status: #{status}")
        {:error, {:unexpected_status, status}}

      {:error, :timeout} ->
        Logger.warning("Analytics platform request timed out")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Analytics platform client error: #{inspect(reason)}")
        {:error, {:client_error, reason}}
    end
  end

  defp normalize_data_points(data) do
    Enum.map(data, fn point ->
      %{
        date: point["date"],
        metric_id: point["metric_id"],
        value: point["value"],
        dimensions: point["dimensions"] || %{}
      }
    end)
  end

  defp store_snapshot(dashboard_id, date_range, data) do
    MetricSnapshot.create!(%{
      dashboard_id: dashboard_id,
      from_date: date_range.from,
      to_date: date_range.to,
      data: data,
      fetched_at: DateTime.utc_now()
    })
  end

  defp build_cache_key(dashboard_id, %{from: from, to: to}) do
    "metrics:#{dashboard_id}:#{Date.to_iso8601(from)}:#{Date.to_iso8601(to)}"
  end

  defp format_metric_descriptor(m), do: %{id: m["id"], name: m["name"], unit: m["unit"]}

  defp get_rate_limit_reset(headers) do
    case List.keyfind(headers, "x-ratelimit-reset", 0) do
      {_, v} -> v
      nil -> "unknown"
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, v} -> String.to_integer(v)
      nil -> 60
    end
  end
end
```
