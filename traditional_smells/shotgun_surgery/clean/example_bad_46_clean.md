```elixir
defmodule MyApp.Reports.Builder do
  @moduledoc """
  Assembles report datasets from the data warehouse for each supported report type.
  Each type queries a different combination of fact tables and applies its own
  aggregation and filtering logic before returning structured rows.
  """

  alias MyApp.DataWarehouse.{FinancialQueries, OperationalQueries, HRQueries}

  def build(:financial, %{period: period, organization_id: org_id} = params) do
    with {:ok, revenue} <- FinancialQueries.revenue_by_period(org_id, period),
         {:ok, expenses} <- FinancialQueries.expenses_by_category(org_id, period),
         {:ok, margins} <- FinancialQueries.gross_margin(org_id, period) do
      {:ok,
       %{
         type: :financial,
         period: period,
         organization_id: org_id,
         generated_at: DateTime.utc_now(),
         data: %{
           revenue: revenue,
           expenses: expenses,
           gross_margin: margins,
           summary: build_financial_summary(revenue, expenses, margins)
         }
       }}
    else
      {:error, reason} -> {:error, {:financial_report_error, reason}}
    end
  end

  def build(:operational, %{period: period, organization_id: org_id} = _params) do
    with {:ok, throughput} <- OperationalQueries.order_throughput(org_id, period),
         {:ok, fulfillment} <- OperationalQueries.fulfillment_rate(org_id, period),
         {:ok, sla_breaches} <- OperationalQueries.sla_breaches(org_id, period) do
      {:ok,
       %{
         type: :operational,
         period: period,
         organization_id: org_id,
         generated_at: DateTime.utc_now(),
         data: %{
           order_throughput: throughput,
           fulfillment_rate: fulfillment,
           sla_breaches: sla_breaches
         }
       }}
    else
      {:error, reason} -> {:error, {:operational_report_error, reason}}
    end
  end

  def build(:hr, %{period: period, organization_id: org_id} = _params) do
    with {:ok, headcount} <- HRQueries.headcount_by_department(org_id, period),
         {:ok, turnover} <- HRQueries.turnover_rate(org_id, period),
         {:ok, absences} <- HRQueries.absence_summary(org_id, period) do
      {:ok,
       %{
         type: :hr,
         period: period,
         organization_id: org_id,
         generated_at: DateTime.utc_now(),
         data: %{
           headcount: headcount,
           turnover_rate: turnover,
           absence_summary: absences
         }
       }}
    else
      {:error, reason} -> {:error, {:hr_report_error, reason}}
    end
  end

  def build(unknown_type, _params) do
    {:error, {:unsupported_report_type, unknown_type}}
  end

  defp build_financial_summary(revenue, expenses, margins) do
    %{
      total_revenue: Enum.sum(Enum.map(revenue, & &1.amount)),
      total_expenses: Enum.sum(Enum.map(expenses, & &1.amount)),
      average_gross_margin: Enum.sum(Enum.map(margins, & &1.rate)) / max(length(margins), 1)
    }
  end
end

defmodule MyApp.Reports.AccessControl do
  @moduledoc """
  Authorizes report access based on user role and report type.
  Different report types expose sensitive data that must be restricted
  to appropriate organizational roles.
  """

  @financial_allowed_roles [:cfo, :finance_manager, :executive, :auditor]
  @operational_allowed_roles [:coo, :operations_manager, :executive, :logistics_lead]
  @hr_allowed_roles [:hr_director, :hr_manager, :executive]

  def authorize(%{role: role}, :financial) do
    if role in @financial_allowed_roles do
      :ok
    else
      {:error, {:unauthorized, :financial, role}}
    end
  end

  def authorize(%{role: role}, :operational) do
    if role in @operational_allowed_roles do
      :ok
    else
      {:error, {:unauthorized, :operational, role}}
    end
  end

  def authorize(%{role: role}, :hr) do
    if role in @hr_allowed_roles do
      :ok
    else
      {:error, {:unauthorized, :hr, role}}
    end
  end

  def authorize(_user, unknown_type) do
    {:error, {:unsupported_report_type, unknown_type}}
  end

  def allowed_types_for(%{role: :executive}), do: [:financial, :operational, :hr]
  def allowed_types_for(%{role: role}) when role in [:cfo, :finance_manager, :auditor], do: [:financial]
  def allowed_types_for(%{role: role}) when role in [:coo, :operations_manager, :logistics_lead], do: [:operational]
  def allowed_types_for(%{role: role}) when role in [:hr_director, :hr_manager], do: [:hr]
  def allowed_types_for(_), do: []
end

defmodule MyApp.Reports.Exporter do
  @moduledoc """
  Serializes assembled report data into the requested output format.
  Supported formats are PDF, CSV, and JSON. Each report type defines
  its own column schema for CSV and section layout for PDF output.
  """

  alias MyApp.Reports.{PdfRenderer, CsvSerializer}

  def export(:financial, report, :pdf) do
    sections = [
      %{title: "Revenue Breakdown", data: report.data.revenue},
      %{title: "Expense Categories", data: report.data.expenses},
      %{title: "Gross Margin", data: report.data.gross_margin}
    ]

    PdfRenderer.render("financial_report", sections, metadata: report_metadata(report))
  end

  def export(:financial, report, :csv) do
    columns = [:period, :category, :amount, :currency]
    rows = Enum.map(report.data.revenue, &Map.take(&1, columns))
    CsvSerializer.serialize(columns, rows)
  end

  def export(:financial, report, :json) do
    {:ok, Jason.encode!(report)}
  end

  def export(:operational, report, :pdf) do
    sections = [
      %{title: "Order Throughput", data: report.data.order_throughput},
      %{title: "Fulfillment Rate", data: report.data.fulfillment_rate},
      %{title: "SLA Breaches", data: report.data.sla_breaches}
    ]

    PdfRenderer.render("operational_report", sections, metadata: report_metadata(report))
  end

  def export(:operational, report, :csv) do
    columns = [:date, :orders_processed, :orders_fulfilled, :breach_count]
    rows = Enum.map(report.data.order_throughput, &Map.take(&1, columns))
    CsvSerializer.serialize(columns, rows)
  end

  def export(:operational, report, :json) do
    {:ok, Jason.encode!(report)}
  end

  def export(:hr, report, :pdf) do
    sections = [
      %{title: "Headcount by Department", data: report.data.headcount},
      %{title: "Turnover Rate", data: report.data.turnover_rate},
      %{title: "Absence Summary", data: report.data.absence_summary}
    ]

    PdfRenderer.render("hr_report", sections, metadata: report_metadata(report))
  end

  def export(:hr, report, :csv) do
    columns = [:department, :headcount, :turnover_pct, :absence_days]
    rows = Enum.map(report.data.headcount, &Map.take(&1, columns))
    CsvSerializer.serialize(columns, rows)
  end

  def export(:hr, report, :json) do
    {:ok, Jason.encode!(report)}
  end

  def export(unknown_type, _report, _format) do
    {:error, {:unsupported_report_type, unknown_type}}
  end

  defp report_metadata(report) do
    %{generated_at: report.generated_at, period: report.period, org: report.organization_id}
  end
end
```
