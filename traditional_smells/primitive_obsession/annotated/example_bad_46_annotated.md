# Annotated Example — Primitive Obsession

## Metadata

- **Smell name:** Primitive Obsession
- **Expected smell location:** `Reporting.SalesReportGenerator` module — `start_date` and `end_date` passed as raw `Date` (or string) primitives in `generate_report/4`, `fetch_sales_data/3`, and `validate_period/2` instead of a `DateRange` struct
- **Affected functions:** `generate_report/4`, `fetch_sales_data/3`, `validate_period/2`, `format_report_header/3`
- **Short explanation:** A reporting period is a cohesive domain concept (a start date and an end date that must be ordered, non-future, and within a maximum span), yet it is split into two separate `Date` primitives everywhere. A `DateRange` struct would co-locate the validation rules, guarantee internal consistency (start ≤ end), and reduce the function arity across the module.

---

```elixir
defmodule Reporting.SalesReportGenerator do
  @moduledoc """
  Generates sales performance reports for a given region and date range.
  Used by the finance team to produce monthly and quarterly summaries.
  """

  require Logger
  alias Reporting.{DataStore, Formatter, ReportCache}

  @max_period_days 366
  @supported_regions ["LATAM", "EMEA", "APAC", "NA", "GLOBAL"]
  @supported_formats ["pdf", "csv", "json", "xlsx"]

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a reporting period — a start date and
  # an end date that must be validated together as a unit — is represented as two
  # separate `Date` primitives (`start_date` and `end_date`) rather than as a
  # dedicated `DateRange` struct. Every function that uses the period must accept
  # two parameters instead of one, and the cross-field constraint (start ≤ end,
  # span ≤ @max_period_days) is duplicated or must be re-checked on every call.
  @spec generate_report(Date.t(), Date.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, String.t()}
  def generate_report(start_date, end_date, region, output_format)
      when is_binary(region) and is_binary(output_format) do
    with :ok <- validate_period(start_date, end_date),
         :ok <- validate_region(region),
         :ok <- validate_format(output_format),
         {:ok, data} <- fetch_sales_data(start_date, end_date, region),
         {:ok, rendered} <- render(data, output_format, start_date, end_date, region) do
      cache_key = build_cache_key(start_date, end_date, region, output_format)
      ReportCache.store(cache_key, rendered)
      Logger.info("Report generated: #{region} #{start_date}–#{end_date} (#{output_format})")
      {:ok, rendered}
    end
  end

  def generate_report(_, _, _, _), do: {:error, "invalid_arguments"}

  @spec validate_period(Date.t(), Date.t()) :: :ok | {:error, String.t()}
  def validate_period(start_date, end_date) do
    today = Date.utc_today()

    cond do
      Date.compare(start_date, end_date) == :gt ->
        {:error, "start_date_must_be_before_end_date"}

      Date.compare(end_date, today) == :gt ->
        {:error, "end_date_cannot_be_in_the_future"}

      Date.diff(end_date, start_date) > @max_period_days ->
        {:error, "period_exceeds_maximum_of_#{@max_period_days}_days"}

      true ->
        :ok
    end
  end

  @spec fetch_sales_data(Date.t(), Date.t(), String.t()) ::
          {:ok, list(map())} | {:error, String.t()}
  def fetch_sales_data(start_date, end_date, region)
      when is_binary(region) do
    case DataStore.query_sales(
           region: region,
           from: start_date,
           to: end_date
         ) do
      {:ok, []} ->
        {:error, "no_data_for_period"}

      {:ok, rows} ->
        Logger.debug("Fetched #{length(rows)} records for #{region} #{start_date}–#{end_date}")
        {:ok, rows}

      {:error, reason} ->
        {:error, "data_store_error: #{reason}"}
    end
  end
  # VALIDATION: SMELL END

  defp render(data, format, start_date, end_date, region) do
    header = format_report_header(start_date, end_date, region)
    summary = compute_summary(data)

    case format do
      "csv"  -> Formatter.to_csv(header, summary, data)
      "json" -> Formatter.to_json(header, summary, data)
      "xlsx" -> Formatter.to_xlsx(header, summary, data)
      "pdf"  -> Formatter.to_pdf(header, summary, data)
    end
  end

  defp format_report_header(start_date, end_date, region) do
    %{
      title: "Sales Report — #{region}",
      period: "#{Date.to_string(start_date)} to #{Date.to_string(end_date)}",
      duration_days: Date.diff(end_date, start_date),
      generated_at: DateTime.utc_now()
    }
  end

  defp compute_summary(data) do
    %{
      total_orders: length(data),
      total_revenue: Enum.sum(Enum.map(data, & &1.amount)),
      avg_order_value:
        if(length(data) > 0,
          do: Enum.sum(Enum.map(data, & &1.amount)) / length(data),
          else: 0.0
        )
    }
  end

  defp build_cache_key(start_date, end_date, region, format) do
    "report:#{region}:#{Date.to_string(start_date)}:#{Date.to_string(end_date)}:#{format}"
  end

  defp validate_region(region) when region in @supported_regions, do: :ok
  defp validate_region(r), do: {:error, "unsupported_region: #{r}"}

  defp validate_format(fmt) when fmt in @supported_formats, do: :ok
  defp validate_format(f), do: {:error, "unsupported_format: #{f}"}
end
```
