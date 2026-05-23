```elixir
defmodule ReportingEngine do
  @moduledoc """
  Generates business reports for revenue, churn, acquisition, and operational metrics.
  """

  alias Reporting.{RevenueStore, ChurnStore, AcquisitionStore, Formatter}

  @max_range_days 365
  @default_granularity :day

  def revenue_report(params) do
    with {:ok, date_from} <- parse_date(params[:date_from]),
         {:ok, date_to} <- parse_date(params[:date_to]),
         :ok <- validate_date_order(date_from, date_to) do

      range_days = Date.diff(date_to, date_from)

      {effective_from, effective_to} =
        if range_days > @max_range_days do
          {Date.add(date_to, -@max_range_days), date_to}
        else
          {date_from, date_to}
        end

      granularity = Map.get(params, :granularity, @default_granularity)

      granularity =
        if granularity in [:day, :week, :month], do: granularity, else: @default_granularity

      rows = RevenueStore.query(effective_from, effective_to, granularity)

      totals = %{
        gross: Enum.sum(Enum.map(rows, & &1.gross)),
        net: Enum.sum(Enum.map(rows, & &1.net)),
        refunds: Enum.sum(Enum.map(rows, & &1.refunds))
      }

      {:ok,
       %{
         report: :revenue,
         from: effective_from,
         to: effective_to,
         granularity: granularity,
         rows: rows,
         totals: totals,
         generated_at: DateTime.utc_now()
       }}
    end
  end

  def churn_report(params) do
    with {:ok, date_from} <- parse_date(params[:date_from]),
         {:ok, date_to} <- parse_date(params[:date_to]),
         :ok <- validate_date_order(date_from, date_to) do

      range_days = Date.diff(date_to, date_from)

      {effective_from, effective_to} =
        if range_days > @max_range_days do
          {Date.add(date_to, -@max_range_days), date_to}
        else
          {date_from, date_to}
        end

      granularity = Map.get(params, :granularity, @default_granularity)

      granularity =
        if granularity in [:day, :week, :month], do: granularity, else: @default_granularity

      rows = ChurnStore.query(effective_from, effective_to, granularity)

      summary = %{
        total_churned: Enum.sum(Enum.map(rows, & &1.churned_count)),
        average_ltv: Formatter.average(Enum.map(rows, & &1.avg_ltv))
      }

      {:ok,
       %{
         report: :churn,
         from: effective_from,
         to: effective_to,
         granularity: granularity,
         rows: rows,
         summary: summary,
         generated_at: DateTime.utc_now()
       }}
    end
  end

  def acquisition_report(params) do
    with {:ok, date_from} <- parse_date(params[:date_from]),
         {:ok, date_to} <- parse_date(params[:date_to]),
         :ok <- validate_date_order(date_from, date_to) do

      rows = AcquisitionStore.query(date_from, date_to)

      {:ok,
       %{
         report: :acquisition,
         from: date_from,
         to: date_to,
         rows: rows,
         generated_at: DateTime.utc_now()
       }}
    end
  end

  defp parse_date(nil), do: {:error, :date_required}
  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, {:invalid_date, value}}
    end
  end
  defp parse_date(%Date{} = d), do: {:ok, d}
  defp parse_date(_), do: {:error, :invalid_date_format}

  defp validate_date_order(from, to) do
    case Date.compare(from, to) do
      :gt -> {:error, :date_from_after_date_to}
      _ -> :ok
    end
  end
end
```
