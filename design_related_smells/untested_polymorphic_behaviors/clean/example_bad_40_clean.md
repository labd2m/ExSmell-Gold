```elixir
defmodule Reporting.DashboardExporter do
  @moduledoc """
  Exports dashboard metrics and dimension breakdowns to CSV and JSON formats.
  Used by the analytics pipeline to feed downstream BI tooling.
  """

  alias Reporting.{MetricQuery, DataPoint}

  @export_formats ~w(csv json)a
  @max_dimension_slug_length 48

  def export(query, format, opts \\ []) do
    unless format in @export_formats do
      raise ArgumentError, "Unsupported export format: #{inspect(format)}"
    end

    with {:ok, results} <- MetricQuery.run(query),
         {:ok, rows} <- build_rows(results, query.dimensions) do
      case format do
        :csv -> serialize_csv(rows, opts)
        :json -> serialize_json(rows, opts)
      end
    end
  end

  def build_rows(data_points, dimensions) do
    rows =
      Enum.map(data_points, fn %DataPoint{} = dp ->
        dimension_cells =
          Enum.map(dimensions, fn dim ->
            slug = slugify_dimension(dim)
            {slug, Map.get(dp.dimensions, dim)}
          end)

        metric_cells = Enum.map(dp.metrics, fn {k, v} -> {to_string(k), v} end)

        Map.new(dimension_cells ++ metric_cells)
      end)

    {:ok, rows}
  end

  def slugify_dimension(dimension) do
    dimension
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[\s\/\\]+/, "_")
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> String.trim("_")
    |> String.slice(0, @max_dimension_slug_length)
  end

  def serialize_csv(rows, opts) when is_list(rows) do
    separator = Keyword.get(opts, :separator, ",")

    case rows do
      [] ->
        {:ok, ""}

      [first | _] ->
        headers = Map.keys(first) |> Enum.join(separator)

        lines =
          Enum.map(rows, fn row ->
            row |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(separator)
          end)

        {:ok, Enum.join([headers | lines], "\n")}
    end
  end

  def serialize_json(rows, _opts) do
    case Jason.encode(rows) do
      {:ok, _} = result -> result
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  def dimension_report(query, dimensions) do
    with {:ok, data_points} <- MetricQuery.run(query) do
      summary =
        Enum.reduce(data_points, %{}, fn dp, acc ->
          Enum.reduce(dimensions, acc, fn dim, inner ->
            slug = slugify_dimension(dim)
            value = Map.get(dp.dimensions, dim, "unknown")
            Map.update(inner, slug, [value], &[value | &1])
          end)
        end)

      {:ok, summary}
    end
  end

  def column_headers(dimensions, metrics) do
    dim_headers = Enum.map(dimensions, &slugify_dimension/1)
    metric_headers = Enum.map(metrics, &to_string/1)
    dim_headers ++ metric_headers
  end
end
```
