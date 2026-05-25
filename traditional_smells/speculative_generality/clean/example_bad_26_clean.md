```elixir
defmodule Reporting.ExportBuilder do
  @moduledoc """
  Builds downloadable export files from report query results.

  Supports filtering by date range, grouping by dimension, and pagination
  through large result sets using cursor-based streaming.
  """

  alias Reporting.{QueryRunner, ColumnSchema, ExportJob}

  require Logger

  @max_rows_per_export 500_000
  @chunk_size 5_000

  @spec build(ExportJob.t()) :: {:ok, String.t()} | {:error, atom()}
  def build(%ExportJob{report_id: report_id, filters: filters, format: format} = job) do
    Logger.info("Starting export job=#{job.id} report=#{report_id} format=#{format}")

    with {:ok, schema} <- ColumnSchema.for_report(report_id),
         {:ok, count} <- QueryRunner.count(report_id, filters),
         :ok <- check_row_limit(count),
         {:ok, path} <- open_temp_file(job.id, format),
         :ok <- write_header(path, schema, format),
         :ok <- stream_rows(report_id, filters, schema, format, path),
         :ok <- finalize_file(path) do
      Logger.info("Export complete job=#{job.id} rows=#{count} path=#{path}")
      {:ok, path}
    else
      {:error, :row_limit_exceeded} ->
        Logger.warning("Export aborted: row limit exceeded job=#{job.id}")
        {:error, :row_limit_exceeded}

      {:error, reason} ->
        Logger.error("Export failed job=#{job.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stream_rows(report_id, filters, schema, format, path) do
    Stream.resource(
      fn -> {0, nil} end,
      fn
        {:done, _} ->
          {:halt, nil}

        {offset, _cursor} ->
          case QueryRunner.fetch_page(report_id, filters, offset, @chunk_size) do
            {:ok, [], _next} -> {:halt, nil}
            {:ok, rows, next_cursor} -> {rows, {offset + @chunk_size, next_cursor}}
            {:error, _} = err -> throw(err)
          end
      end,
      fn _ -> :ok end
    )
    |> Stream.each(fn row ->
      line = serialize_row(row, schema, format)
      File.write!(path, line, [:append])
    end)
    |> Stream.run()
  rescue
    e -> {:error, e}
  end

  defp write_header(path, schema, format) do
    header = serialize_header(schema, format)
    File.write(path, header)
  end

  defp serialize_header(schema, :csv) do
    schema.columns
    |> Enum.map(& &1.label)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp serialize_rows(rows, export_format) do
    case export_format do
      _ -> Enum.map_join(rows, "\n", &csv_line/1)
    end
  end

  defp serialize_row(row, schema, _format) do
    schema.columns
    |> Enum.map(fn col -> Map.get(row, col.key, "") |> to_string() end)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp csv_line(row) when is_map(row) do
    row |> Map.values() |> Enum.map(&to_string/1) |> Enum.join(",")
  end

  defp open_temp_file(job_id, _format) do
    path = "/tmp/exports/#{job_id}.csv"
    File.mkdir_p!(Path.dirname(path))
    {:ok, path}
  end

  defp finalize_file(path) do
    if File.exists?(path), do: :ok, else: {:error, :file_missing}
  end

  defp check_row_limit(count) when count > @max_rows_per_export,
    do: {:error, :row_limit_exceeded}

  defp check_row_limit(_count), do: :ok
end
```
