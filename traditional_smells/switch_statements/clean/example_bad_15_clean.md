```elixir
defmodule MetricsAggregator do
  @moduledoc """
  Aggregates time-series metrics data into bucketed summaries at different
  granularities. Used by the reporting and observability subsystems to build
  dashboards, run scheduled reports, and enforce data retention policies.
  """

  require Logger

  @periods [:minutely, :hourly, :daily, :monthly]

  def valid_periods, do: @periods







  @doc """
  Returns the duration in seconds of a single time bucket for this period.
  """
  def bucket_duration_seconds(%{period: period}) do
    case period do
      :minutely -> 60
      :hourly -> 3_600
      :daily -> 86_400
      :monthly -> 2_592_000
      _ -> 3_600
    end
  end

  @doc """
  Returns the number of days that aggregated data at this granularity should
  be retained before being pruned from storage.
  """
  def retention_days(%{period: period}) do
    case period do
      :minutely -> 2
      :hourly -> 30
      :daily -> 365
      :monthly -> 1_825
      _ -> 30
    end
  end

  @doc """
  Returns a human-readable label for the aggregation period, used in chart
  axis labels and report headings.
  """
  def period_label(%{period: period}) do
    case period do
      :minutely -> "Per Minute"
      :hourly -> "Per Hour"
      :daily -> "Per Day"
      :monthly -> "Per Month"
      _ -> "Custom"
    end
  end



  @doc """
  Computes the timestamp of the bucket boundary that contains `dt`.
  Truncates to the start of the relevant time unit.
  """
  def bucket_start(%{period: period}, %DateTime{} = dt) do
    case period do
      :minutely ->
        %{dt | second: 0, microsecond: {0, 0}}

      :hourly ->
        %{dt | minute: 0, second: 0, microsecond: {0, 0}}

      :daily ->
        DateTime.new!(DateTime.to_date(dt), ~T[00:00:00], "Etc/UTC")

      :monthly ->
        date = DateTime.to_date(dt)
        DateTime.new!(Date.new!(date.year, date.month, 1), ~T[00:00:00], "Etc/UTC")

      _ ->
        %{dt | minute: 0, second: 0, microsecond: {0, 0}}
    end
  end

  @doc """
  Groups a flat list of metric events into time buckets for the given period.
  Returns a map of `bucket_start_datetime => list_of_events`.
  """
  def bucket_events(%{period: _period} = opts, events) when is_list(events) do
    Enum.group_by(events, fn event ->
      bucket_start(opts, event.recorded_at)
    end)
  end

  @doc """
  Aggregates bucketed events into summary statistics per bucket.
  """
  def aggregate(%{} = opts, events) do
    label = period_label(opts)
    duration = bucket_duration_seconds(opts)

    events
    |> bucket_events(opts)
    |> Enum.map(fn {bucket_ts, bucket_events} ->
      values = Enum.map(bucket_events, & &1.value)
      count = length(values)
      sum = Enum.sum(values)
      avg = if count > 0, do: sum / count, else: 0.0
      min = if count > 0, do: Enum.min(values), else: nil
      max = if count > 0, do: Enum.max(values), else: nil

      %{
        bucket_start: bucket_ts,
        period_label: label,
        bucket_seconds: duration,
        count: count,
        sum: sum,
        average: Float.round(avg, 4),
        min: min,
        max: max
      }
    end)
    |> Enum.sort_by(& &1.bucket_start, DateTime)
  end

  @doc """
  Prunes metric records older than the retention window for the given period.
  Returns the cutoff DateTime that was used.
  """
  def prune_cutoff(%{} = opts) do
    days = retention_days(opts)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Logger.info("Pruning #{opts.period} metrics older than #{days} days (before #{cutoff}).")
    cutoff
  end
end
```
