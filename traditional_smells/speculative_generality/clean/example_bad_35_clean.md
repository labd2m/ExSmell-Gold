```elixir
defmodule Reporting.RevenueReport do
  @moduledoc """
  Generates revenue reports aggregated by time period and dimension.

  Reports can be grouped by day, week, month, or quarter and further
  segmented by product line, region, or sales channel.
  """

  alias Reporting.{QueryBuilder, DataFormatter, ReportCache, ReportMetadata}

  require Logger

  @supported_groupings [:day, :week, :month, :quarter]
  @supported_dimensions [:product_line, :region, :channel, :none]
  @cache_ttl_seconds 3_600

  @spec generate(map()) :: {:ok, map()} | {:error, atom()}
  def generate(%{from: from, to: to} = params) do
    grouping = Map.get(params, :grouping, :month)
    dimension = Map.get(params, :dimension, :none)

    with :ok <- validate_grouping(grouping),
         :ok <- validate_dimension(dimension),
         :ok <- validate_date_range(from, to),
         cache_key = build_cache_key(params),
         {:miss, _} <- ReportCache.get(cache_key),
         {:ok, raw_rows} <- QueryBuilder.revenue(from, to, grouping, dimension),
         {:ok, formatted} <- DataFormatter.format_revenue(raw_rows, grouping, dimension) do
      metadata = ReportMetadata.build(params, length(raw_rows))
      result = %{data: formatted, metadata: metadata}
      ReportCache.put(cache_key, result, @cache_ttl_seconds)
      Logger.info("Revenue report generated rows=#{length(raw_rows)} grouping=#{grouping}")
      {:ok, result}
    else
      {:hit, cached} ->
        Logger.debug("Revenue report served from cache")
        {:ok, cached}

      {:error, reason} ->
        Logger.error("Revenue report failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def generate_delta(base_params, comparison_params, opts \\ []) do
    label_base = Keyword.get(opts, :label_base, "current")
    label_comparison = Keyword.get(opts, :label_comparison, "previous")

    with {:ok, base_report} <- generate(base_params),
         {:ok, comparison_report} <- generate(comparison_params),
         {:ok, delta} <- compute_delta(base_report.data, comparison_report.data) do
      {:ok,
       %{
         base: %{label: label_base, data: base_report.data},
         comparison: %{label: label_comparison, data: comparison_report.data},
         delta: delta,
         generated_at: DateTime.utc_now()
       }}
    end
  end

  defp compute_delta(base_rows, comparison_rows) do
    comparison_map =
      Map.new(comparison_rows, fn row -> {row.period, row.revenue} end)

    delta_rows =
      Enum.map(base_rows, fn row ->
        prev = Map.get(comparison_map, row.period, 0.0)
        change = if prev == 0, do: nil, else: Float.round((row.revenue - prev) / prev * 100, 2)
        Map.put(row, :period_over_period_pct, change)
      end)

    {:ok, delta_rows}
  end

  defp validate_grouping(g) when g in @supported_groupings, do: :ok
  defp validate_grouping(g), do: {:error, {:invalid_grouping, g}}

  defp validate_dimension(d) when d in @supported_dimensions, do: :ok
  defp validate_dimension(d), do: {:error, {:invalid_dimension, d}}

  defp validate_date_range(from, to) do
    if Date.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_date_range}
  end

  defp build_cache_key(params) do
    :crypto.hash(:md5, :erlang.term_to_binary(params)) |> Base.encode16(case: :lower)
  end
end
```
