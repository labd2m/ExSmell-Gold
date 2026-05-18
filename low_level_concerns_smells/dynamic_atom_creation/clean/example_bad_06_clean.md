```elixir
defmodule MyApp.Reporting.ReportEngine do
  @moduledoc """
  Processes CSV report uploads, validates their structure, and persists
  normalized rows into the data warehouse for further analysis.
  """

  require Logger

  alias MyApp.Reporting.{ReportSchema, RowValidator, DataWarehouse}
  alias NimbleCSV.RFC4180, as: CSV

  @max_rows 100_000
  @required_columns ~w(date amount currency category reference)

  @doc """
  Ingests a raw CSV binary uploaded by a user.
  Returns `{:ok, report_id}` or `{:error, reason}`.
  """
  @spec ingest(binary(), integer()) :: {:ok, String.t()} | {:error, term()}
  def ingest(csv_binary, user_id) when is_binary(csv_binary) do
    Logger.info("Starting report ingestion", user_id: user_id)

    with {:ok, rows} <- parse_csv(csv_binary),
         :ok <- check_row_limit(rows),
         {:ok, headers} <- extract_headers(rows),
         :ok <- validate_headers(headers),
         {:ok, column_map} <- build_column_map(headers),
         {:ok, records} <- normalize_rows(rows, column_map),
         :ok <- RowValidator.validate_all(records),
         {:ok, report_id} <- DataWarehouse.insert_report(user_id, records) do
      Logger.info("Report ingestion complete", report_id: report_id, row_count: length(records))
      {:ok, report_id}
    else
      {:error, reason} = err ->
        Logger.error("Report ingestion failed", reason: inspect(reason), user_id: user_id)
        err
    end
  end

  defp parse_csv(binary) do
    rows = CSV.parse_string(binary, skip_headers: false)
    {:ok, rows}
  rescue
    e -> {:error, {:csv_parse_error, Exception.message(e)}}
  end

  defp check_row_limit(rows) when length(rows) > @max_rows + 1, do: {:error, :too_many_rows}
  defp check_row_limit(_), do: :ok

  defp extract_headers([headers | _rest]), do: {:ok, headers}
  defp extract_headers([]), do: {:error, :empty_csv}

  defp validate_headers(headers) do
    missing = @required_columns -- headers

    if missing == [] do
      :ok
    else
      {:error, {:missing_columns, missing}}
    end
  end

  defp build_column_map(headers) do
    column_map =
      headers
      |> Enum.with_index()
      |> Map.new(fn {header, index} -> {index, String.to_atom(header)} end)

    {:ok, column_map}
  end

  defp normalize_rows([_headers | data_rows], column_map) do
    records =
      data_rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, line_number} ->
        row
        |> Enum.with_index()
        |> Map.new(fn {value, idx} ->
          key = Map.get(column_map, idx, :"unknown_#{idx}")
          {key, value}
        end)
        |> Map.put(:_line, line_number)
      end)

    {:ok, records}
  end
end
```
