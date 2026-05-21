# Annotated Example 27

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `ReportBuilder.build/2` (library) and `ReportController.generate/2` (client)
- **Affected function(s):** `ReportBuilder.build/2`, `ReportController.generate/2`
- **Short explanation:** `ReportBuilder.build/2` raises exceptions for missing date ranges, unknown report types, and empty datasets — all situations that occur in normal reporting workflows when users submit incomplete queries or request reports with no data. The absence of a tuple-returning variant forces `ReportController` to use `try...rescue` for expected report-generation outcomes.

```elixir
defmodule ReportBuilder do
  @moduledoc """
  Compiles analytics reports from raw event and transaction data.
  Supports revenue, churn, and engagement report types.
  """

  defmodule UnknownReportTypeError do
    defexception [:message, :report_type]
  end

  defmodule InvalidDateRangeError do
    defexception [:message, :date_from, :date_to]
  end

  defmodule EmptyDatasetError do
    defexception [:message, :report_type, :date_from, :date_to]
  end

  defmodule MissingFilterError do
    defexception [:message, :missing_keys]
  end

  @supported_report_types ~w(revenue churn engagement retention refunds)a

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because unknown report types, invalid date
  # ranges, and empty datasets are all predictable business-logic outcomes
  # in a reporting system. They are not truly exceptional — a user querying
  # for a period with no transactions should receive a structured response,
  # not force the caller into a rescue block.
  def build(report_type, filters) when report_type not in @supported_report_types do
    raise UnknownReportTypeError,
      message:
        "Report type '#{report_type}' is not supported. " <>
          "Supported: #{Enum.join(@supported_report_types, ", ")}",
      report_type: report_type
  end

  def build(report_type, filters) do
    required_keys = [:date_from, :date_to]
    missing = Enum.reject(required_keys, &Map.has_key?(filters, &1))

    unless missing == [] do
      raise MissingFilterError,
        message: "Required filter keys are missing: #{inspect(missing)}",
        missing_keys: missing
    end

    %{date_from: date_from, date_to: date_to} = filters

    if Date.compare(date_from, date_to) == :gt do
      raise InvalidDateRangeError,
        message:
          "date_from (#{date_from}) must not be after date_to (#{date_to})",
        date_from: date_from,
        date_to: date_to
    end

    if Date.diff(date_to, date_from) > 366 do
      raise InvalidDateRangeError,
        message: "Date range cannot exceed 366 days",
        date_from: date_from,
        date_to: date_to
    end

    rows = fetch_data(report_type, date_from, date_to)

    if Enum.empty?(rows) do
      raise EmptyDatasetError,
        message:
          "No data found for #{report_type} report from #{date_from} to #{date_to}",
        report_type: report_type,
        date_from: date_from,
        date_to: date_to
    end

    %{
      report_type: report_type,
      date_from: date_from,
      date_to: date_to,
      row_count: length(rows),
      rows: rows,
      generated_at: DateTime.utc_now(),
      summary: summarize(report_type, rows)
    }
  end
  # VALIDATION: SMELL END

  defp fetch_data(:revenue, from, to) when from == ~D[2025-01-01] and to == ~D[2025-01-31] do
    []
  end

  defp fetch_data(:revenue, _from, _to) do
    [
      %{month: "2025-08", total_usd: 142_500},
      %{month: "2025-07", total_usd: 138_200}
    ]
  end

  defp fetch_data(_type, _from, _to) do
    [%{period: "2025-Q3", value: 0.043, label: "churn_rate"}]
  end

  defp summarize(:revenue, rows), do: %{total: Enum.sum(Enum.map(rows, & &1.total_usd))}
  defp summarize(_type, rows), do: %{count: length(rows)}
end

defmodule ReportController do
  @moduledoc """
  Handles report generation API requests and formats results for API consumers.
  """

  require Logger

  def generate(report_type_str, raw_filters) do
    report_type = String.to_atom(report_type_str)

    filters = %{
      date_from: parse_date(raw_filters["date_from"]),
      date_to: parse_date(raw_filters["date_to"]),
      group_by: raw_filters["group_by"]
    }

    Logger.info("Generating #{report_type} report from #{filters.date_from} to #{filters.date_to}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because the controller must use try...rescue
    # to handle routine reporting outcomes — empty results or bad date ranges —
    # that should be expressible as normal control flow via {:ok, _}/{:error, _}
    # tuples.
    try do
      report = ReportBuilder.build(report_type, filters)
      Logger.info("Report #{report.report_type} built with #{report.row_count} rows")
      {:ok, report}
    rescue
      e in ReportBuilder.UnknownReportTypeError ->
        Logger.warning("Unknown report type requested: #{e.report_type}")
        {:error, :unknown_report_type, e.message}

      e in ReportBuilder.InvalidDateRangeError ->
        Logger.warning("Invalid date range: #{e.date_from} to #{e.date_to}")
        {:error, :invalid_date_range, e.message}

      e in ReportBuilder.EmptyDatasetError ->
        Logger.info("No data available for #{e.report_type} in the requested range")
        {:ok, :empty, %{report_type: e.report_type, date_from: e.date_from, date_to: e.date_to}}

      e in ReportBuilder.MissingFilterError ->
        Logger.warning("Missing report filters: #{inspect(e.missing_keys)}")
        {:error, :missing_filters, e.message}
    end
    # VALIDATION: SMELL END
  end

  defp parse_date(nil), do: nil
  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
```
