# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `MetricsCollector.record/4`, where `value` is passed to `Enum.sum/1` via aggregation
- **Affected function(s):** `record/4`, `aggregate_window/3`
- **Short explanation:** The `value` parameter is pushed into an ETS-backed time-series buffer and later passed to `Enum.sum/1` inside `aggregate_window/3` without any upfront type check that it is a number. Passing a binary or atom causes an `ArithmeticError` inside `Enum.sum/1`, which is far from the `record/4` entry point where the invalid data was accepted.

```elixir
defmodule MyApp.Analytics.MetricsCollector do
  @moduledoc """
  Collects, buffers, and aggregates application metrics including counters,
  gauges, histograms, and custom event values. Flushes to the metrics backend
  on a configurable interval.
  """

  require Logger

  alias MyApp.Analytics.{MetricsStore, MetricsBackend, MetricsDashboard}

  @flush_interval_ms 10_000
  @max_buffer_size 10_000
  @supported_metric_types [:counter, :gauge, :histogram, :event]
  @default_aggregation_window_s 60

  @type metric_opts :: [
          tags: map(),
          unit: String.t(),
          aggregation: :sum | :avg | :max | :min | :last
        ]

  @spec record(String.t(), atom(), term(), metric_opts()) :: :ok | {:error, atom()}
  def record(metric_name, type, value, opts \\ []) do
    tags = Keyword.get(opts, :tags, %{})
    unit = Keyword.get(opts, :unit, "none")
    aggregation = Keyword.get(opts, :aggregation, :sum)

    with :ok <- validate_metric_type(type),
         :ok <- validate_metric_name(metric_name) do
      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `value` is stored in the metrics buffer
      # VALIDATION: and later used in `Enum.sum/1` inside `aggregate_window/3`
      # VALIDATION: without any check that it is a number at the point of entry.
      # VALIDATION: If a caller passes a string like "42" or an atom, the error
      # VALIDATION: will only surface during aggregation inside Enum.sum,
      # VALIDATION: making it very hard to trace back to the original bad call.
      datapoint = %{
        name: metric_name,
        type: type,
        value: value,
        tags: tags,
        unit: unit,
        aggregation: aggregation,
        recorded_at: System.system_time(:millisecond)
      }
      # VALIDATION: SMELL END

      case MetricsStore.push(datapoint) do
        :ok ->
          maybe_flush_if_full()
          :ok

        {:error, :buffer_full} ->
          Logger.warning("Metrics buffer full, dropping datapoint for #{metric_name}")
          {:error, :buffer_full}
      end
    end
  end

  @spec aggregate_window(String.t(), pos_integer(), atom()) ::
          {:ok, number()} | {:error, atom()}
  def aggregate_window(metric_name, window_s \\ @default_aggregation_window_s, aggregation \\ :sum) do
    cutoff_ms = System.system_time(:millisecond) - window_s * 1_000

    with {:ok, datapoints} <- MetricsStore.fetch_since(metric_name, cutoff_ms) do
      values = Enum.map(datapoints, & &1.value)

      result =
        case aggregation do
          :sum -> Enum.sum(values)
          :avg -> Enum.sum(values) / max(length(values), 1)
          :max -> Enum.max(values, fn -> 0 end)
          :min -> Enum.min(values, fn -> 0 end)
          :last -> List.last(values) || 0
        end

      {:ok, result}
    end
  end

  @spec flush() :: {:ok, integer()}
  def flush do
    with {:ok, datapoints} <- MetricsStore.drain() do
      batches = Enum.chunk_every(datapoints, 500)

      sent =
        Enum.reduce(batches, 0, fn batch, acc ->
          case MetricsBackend.send_batch(batch) do
            {:ok, count} -> acc + count
            {:error, _} -> acc
          end
        end)

      Logger.debug("Metrics flushed: #{sent} datapoints sent to backend")
      {:ok, sent}
    end
  end

  @spec dashboard_summary([String.t()], pos_integer()) :: {:ok, map()}
  def dashboard_summary(metric_names, window_s \\ 300) do
    results =
      Map.new(metric_names, fn name ->
        case aggregate_window(name, window_s) do
          {:ok, value} -> {name, value}
          {:error, _} -> {name, nil}
        end
      end)

    {:ok, results}
  end

  # Private helpers

  defp validate_metric_type(type) when type in @supported_metric_types, do: :ok
  defp validate_metric_type(_), do: {:error, :unsupported_metric_type}

  defp validate_metric_name(name) when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 200,
    do: :ok

  defp validate_metric_name(_), do: {:error, :invalid_metric_name}

  defp maybe_flush_if_full do
    case MetricsStore.size() do
      size when size >= @max_buffer_size -> flush()
      _ -> :ok
    end
  end
end
```
