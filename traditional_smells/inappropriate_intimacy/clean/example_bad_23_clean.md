```elixir
defmodule MyApp.Analytics.MetricAggregator do
  @moduledoc """
  Executes metric definitions against registered data sources and
  stores aggregated results for dashboard consumption.
  """

  alias MyApp.Analytics.{DataSource, MetricDefinition, MetricSnapshot}
  alias MyApp.Analytics.QueryExecutor
  alias MyApp.Alerting.ThresholdAlert

  def aggregate(metric_id, as_of \\ DateTime.utc_now()) do
    with {:ok, metric_def} <- MetricDefinition.fetch(metric_id),
         {:ok, source}     <- DataSource.fetch(metric_def.source_id) do

      conn_params       = source.connection_params
      query_template    = source.query_template
      refresh_interval  = source.refresh_interval_seconds

      aggregation_fn    = metric_def.aggregation_fn
      unit              = metric_def.unit
      threshold_alerts  = metric_def.threshold_alerts

      last_snapshot = MetricSnapshot.latest_for(metric_id)
      stale = case last_snapshot do
        nil -> true
        s   -> DateTime.diff(as_of, s.computed_at, :second) >= refresh_interval
      end

      if stale do
        query  = build_query(query_template, as_of)
        rows   = QueryExecutor.run(conn_params, query)
        value  = apply_aggregation(aggregation_fn, rows)

        snapshot = %{
          id:           generate_id(),
          metric_id:    metric_id,
          value:        value,
          unit:         unit,
          computed_at:  as_of,
          row_count:    length(rows)
        }

        MetricSnapshot.save(snapshot)

        Enum.each(threshold_alerts, fn alert ->
          if threshold_breached?(alert, value) do
            ThresholdAlert.fire(metric_id, alert.name, value, alert.threshold)
          end
        end)

        {:ok, snapshot}
      else
        {:ok, last_snapshot}
      end
    end
  end

  def aggregate_many(metric_ids) do
    metric_ids
    |> Task.async_stream(&aggregate/1, max_concurrency: 10, timeout: 30_000)
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, snap}},  {ok, err} -> {[snap | ok], err}
      {:ok, {:error, r}},  {ok, err} -> {ok, [r | err]}
      {:exit, _},          {ok, err} -> {ok, [:timeout | err]}
    end)
  end

  def history(metric_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    MetricSnapshot.list_for(metric_id, limit: limit)
  end


  defp build_query(template, as_of) do
    timestamp = DateTime.to_iso8601(as_of)
    String.replace(template, "{{as_of}}", timestamp)
  end

  defp apply_aggregation(:sum, rows),  do: rows |> Enum.map(&elem(&1, 0)) |> Enum.sum()
  defp apply_aggregation(:avg, []),    do: 0.0
  defp apply_aggregation(:avg, rows),  do: Enum.sum(Enum.map(rows, &elem(&1, 0))) / length(rows)
  defp apply_aggregation(:max, rows),  do: rows |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)
  defp apply_aggregation(:min, rows),  do: rows |> Enum.map(&elem(&1, 0)) |> Enum.min(fn -> 0 end)
  defp apply_aggregation(:count, rows), do: length(rows)
  defp apply_aggregation(_, rows),     do: length(rows)

  defp threshold_breached?(%{operator: :gt, threshold: t}, value), do: value > t
  defp threshold_breached?(%{operator: :lt, threshold: t}, value), do: value < t
  defp threshold_breached?(%{operator: :eq, threshold: t}, value), do: value == t
  defp threshold_breached?(_, _), do: false

  defp generate_id do
    "MTR-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
