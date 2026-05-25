# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `MetricAggregator.sql_function/1` and `MetricAggregator.aggregation_label/1`
- **Affected functions:** `sql_function/1`, `aggregation_label/1`
- **Short explanation:** The same `case` branching over aggregation type (`:sum`, `:avg`, `:min`, `:max`, `:count`) is duplicated in `sql_function/1` and `aggregation_label/1`. Adding a new aggregation type forces changes in both.

---

```elixir
defmodule MetricAggregator do
  @moduledoc """
  Builds and executes dynamic metric aggregation queries for an
  analytics reporting module. Supports multiple aggregation functions
  applied over configurable time windows.
  """

  alias MetricAggregator.{ReportDefinition, DataPoint, QueryBuilder}

  @type aggregation_type :: :sum | :avg | :min | :max | :count

  @spec run_report(ReportDefinition.t()) :: {:ok, [DataPoint.t()]} | {:error, term()}
  def run_report(%ReportDefinition{} = definition) do
    with {:ok, query} <- build_query(definition),
         {:ok, raw_results} <- QueryBuilder.execute(query) do
      data_points =
        Enum.map(raw_results, fn row ->
          %DataPoint{
            period: row.period,
            value: row.value,
            label: aggregation_label(definition.aggregation),
            aggregation: definition.aggregation
          }
        end)

      {:ok, data_points}
    end
  end

  @spec build_query(ReportDefinition.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp build_query(%ReportDefinition{} = definition) do
    agg_fn = sql_function(definition.aggregation)
    {:ok, """
    SELECT
      date_trunc('#{definition.time_grain}', recorded_at) AS period,
      #{agg_fn}(#{definition.metric_column}) AS value
    FROM #{definition.table}
    WHERE recorded_at BETWEEN '#{definition.start_date}' AND '#{definition.end_date}'
    GROUP BY period
    ORDER BY period ASC
    """}
  end

  @spec preview_config(ReportDefinition.t()) :: map()
  def preview_config(%ReportDefinition{} = definition) do
    %{
      aggregation: definition.aggregation,
      label: aggregation_label(definition.aggregation),
      sql_fn: sql_function(definition.aggregation),
      metric: definition.metric_column,
      table: definition.table,
      time_grain: definition.time_grain
    }
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `aggregation`
  # also appears in `aggregation_label/1` below. Both enumerate :sum, :avg, :min,
  # :max, :count — adding a new aggregation requires updating both case blocks.
  @spec sql_function(aggregation_type()) :: String.t()
  def sql_function(aggregation) do
    case aggregation do
      :sum   -> "SUM"
      :avg   -> "AVG"
      :min   -> "MIN"
      :max   -> "MAX"
      :count -> "COUNT"
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `aggregation`
  # already appeared in `sql_function/1` above. The aggregation atoms are fully
  # repeated here, creating a fragile pair of functions that must be kept in sync.
  @spec aggregation_label(aggregation_type()) :: String.t()
  def aggregation_label(aggregation) do
    case aggregation do
      :sum   -> "Total"
      :avg   -> "Average"
      :min   -> "Minimum"
      :max   -> "Maximum"
      :count -> "Count"
    end
  end
  # VALIDATION: SMELL END

  @spec supported_aggregations() :: [aggregation_type()]
  def supported_aggregations, do: [:sum, :avg, :min, :max, :count]

  @spec valid_aggregation?(atom()) :: boolean()
  def valid_aggregation?(agg), do: agg in supported_aggregations()

  @spec compare_periods(ReportDefinition.t(), ReportDefinition.t()) :: map()
  def compare_periods(%ReportDefinition{} = current, %ReportDefinition{} = previous) do
    with {:ok, current_data} <- run_report(current),
         {:ok, previous_data} <- run_report(previous) do
      current_total = Enum.sum(Enum.map(current_data, & &1.value))
      previous_total = Enum.sum(Enum.map(previous_data, & &1.value))
      change = if previous_total != 0, do: (current_total - previous_total) / previous_total, else: nil

      %{current: current_total, previous: previous_total, change_pct: change}
    end
  end
end
```
