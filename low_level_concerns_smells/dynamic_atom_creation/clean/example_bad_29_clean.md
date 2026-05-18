```elixir
defmodule Reporting.CsvImporter do
  @moduledoc """
  Handles import of CSV-based financial reports uploaded by customers.
  Parses, validates, and persists report rows for downstream aggregation.
  """

  require Logger

  alias Reporting.{ReportRepo, ReportRow, ValidationPipeline}

  @max_rows 50_000
  @required_columns ~w(account_id period amount currency category)
  @allowed_extensions [".csv"]

  @spec import(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def import(file_path, %{user_id: user_id, report_name: report_name}) do
    Logger.info("Starting CSV import", user_id: user_id, file: file_path)

    with :ok <- validate_extension(file_path),
         {:ok, raw_rows} <- parse_csv(file_path),
         :ok <- validate_row_count(raw_rows),
         {:ok, headers} <- extract_headers(raw_rows),
         :ok <- validate_required_columns(headers),
         {:ok, report} <- ReportRepo.create_report(%{name: report_name, user_id: user_id}),
         {:ok, stats} <- process_rows(raw_rows, headers, report.id) do
      Logger.info("CSV import complete", report_id: report.id, stats: inspect(stats))
      {:ok, Map.put(stats, :report_id, report.id)}
    else
      {:error, reason} = err ->
        Logger.error("CSV import failed", user_id: user_id, reason: inspect(reason))
        err
    end
  end

  defp validate_extension(path) do
    ext = Path.extname(path) |> String.downcase()
    if ext in @allowed_extensions, do: :ok, else: {:error, {:invalid_extension, ext}}
  end

  defp parse_csv(path) do
    case File.read(path) do
      {:ok, content} ->
        rows =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, ","))

        {:ok, rows}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp validate_row_count(rows) when length(rows) <= @max_rows + 1, do: :ok
  defp validate_row_count(_), do: {:error, :too_many_rows}

  defp extract_headers([header_row | _]), do: {:ok, header_row}
  defp extract_headers([]), do: {:error, :empty_file}

  defp validate_required_columns(headers) do
    missing = @required_columns -- headers
    if missing == [], do: :ok, else: {:error, {:missing_columns, missing}}
  end

  defp process_rows([_headers | data_rows], headers, report_id) do
    {ok, errors} =
      data_rows
      |> Stream.with_index(2)
      |> Enum.reduce({0, []}, fn {row, line_number}, {ok_count, err_acc} ->
        case build_report_row(row, headers) do
          {:ok, attrs} ->
            case ReportRepo.insert_row(Map.put(attrs, :report_id, report_id)) do
              {:ok, _} -> {ok_count + 1, err_acc}
              {:error, changeset} -> {ok_count, [{line_number, changeset} | err_acc]}
            end

          {:error, reason} ->
            {ok_count, [{line_number, reason} | err_acc]}
        end
      end)

    {:ok, %{inserted: ok, errors: length(errors), error_details: Enum.reverse(errors)}}
  end

  defp build_report_row(values, headers) do
    if length(values) != length(headers) do
      {:error, :column_count_mismatch}
    else
      attrs =
        headers
        |> Enum.zip(values)
        |> Enum.into(%{}, fn {header, value} ->
          {cast_field_name(header), value}
        end)

      ValidationPipeline.validate(attrs)
    end
  end

  defp cast_field_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end
end
```
