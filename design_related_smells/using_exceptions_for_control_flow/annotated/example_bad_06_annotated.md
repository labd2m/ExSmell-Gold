# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Reporting.ReportBuilder.build/2`
- **Affected function(s):** `Reporting.ReportBuilder.build/2` (library side); `Reporting.ScheduledExporter.export_pending/1` (client side)
- **Explanation:** `build/2` raises `RuntimeError` for entirely predictable problems: an unsupported report type, an invalid date range, and missing required parameters. These are mundane validation failures that a caller should be able to handle as data. Forcing `try/rescue` means clients cannot treat report-generation failures as normal results.

```elixir
defmodule Reporting.DateRange do
  @moduledoc "Validated date range used to scope report data."

  @enforce_keys [:from, :to]
  defstruct [:from, :to]

  def new(from, to) do
    if Date.compare(from, to) in [:lt, :eq] do
      {:ok, %__MODULE__{from: from, to: to}}
    else
      {:error, "from_date must not be after to_date"}
    end
  end

  def days(%__MODULE__{from: from, to: to}), do: Date.diff(to, from)
end

defmodule Reporting.ReportSpec do
  @moduledoc "Describes the parameters for a requested report."

  @enforce_keys [:type, :date_range, :requested_by]
  defstruct [:type, :date_range, :requested_by, :filters, :format]
end

defmodule Reporting.DataSource do
  @moduledoc "Fetches aggregated metrics from the analytics store."

  def sales_summary(date_range) do
    {:ok,
     %{
       total_revenue: 128_450.0,
       order_count: 847,
       average_order_value: 151.65,
       period: date_range
     }}
  end

  def inventory_snapshot(_date_range) do
    {:ok, %{sku_count: 312, total_units: 14_200, low_stock_count: 18}}
  end

  def user_acquisition(_date_range) do
    {:ok, %{new_users: 1_230, churn: 98, net_growth: 1_132}}
  end
end

defmodule Reporting.ReportBuilder do
  @moduledoc """
  Constructs structured report payloads from a ReportSpec.
  Validates parameters and delegates to the appropriate data source
  before assembling the final report document.
  """

  alias Reporting.{DataSource, DateRange, ReportSpec}
  require Logger

  @supported_types [:sales_summary, :inventory_snapshot, :user_acquisition]
  @max_range_days 366

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `build/2` raises RuntimeError for three
  # VALIDATION: routine validation outcomes: unsupported report type, excessive date
  # VALIDATION: range, and missing requested_by field. These are expected domain
  # VALIDATION: constraints, not system failures. Callers processing a queue of
  # VALIDATION: scheduled reports have no way to continue past a single failure
  # VALIDATION: without wrapping every call in try/rescue.
  def build(%ReportSpec{} = spec, opts \\ []) do
    unless spec.type in @supported_types do
      raise RuntimeError,
        message:
          "Unsupported report type ':#{spec.type}'. " <>
            "Supported: #{Enum.map_join(@supported_types, ", ", &":#{&1}")}"
    end

    unless is_binary(spec.requested_by) and String.length(spec.requested_by) > 0 do
      raise RuntimeError, message: "Report spec must include a non-empty 'requested_by' field"
    end

    days = DateRange.days(spec.date_range)

    if days > @max_range_days do
      raise RuntimeError,
        message:
          "Date range spans #{days} days, which exceeds the maximum of #{@max_range_days} days"
    end

    _format = Keyword.get(opts, :format, :json)

    data =
      case spec.type do
        :sales_summary ->
          {:ok, payload} = DataSource.sales_summary(spec.date_range)
          payload

        :inventory_snapshot ->
          {:ok, payload} = DataSource.inventory_snapshot(spec.date_range)
          payload

        :user_acquisition ->
          {:ok, payload} = DataSource.user_acquisition(spec.date_range)
          payload
      end

    report = %{
      id: "rpt_#{:rand.uniform(999_999)}",
      type: spec.type,
      requested_by: spec.requested_by,
      generated_at: DateTime.utc_now(),
      period: %{from: spec.date_range.from, to: spec.date_range.to},
      data: data
    }

    Logger.info("Report #{report.id} (#{spec.type}) built for #{spec.requested_by}")
    report
  end
  # VALIDATION: SMELL END
end

defmodule Reporting.ScheduledExporter do
  @moduledoc """
  Runs a list of pending report specs and exports each result.
  Collects failures without aborting the entire export run.
  """

  alias Reporting.ReportBuilder
  require Logger

  def export_pending(pending_specs) when is_list(pending_specs) do
    Enum.reduce(pending_specs, %{built: [], failed: []}, fn spec, acc ->
      # Client forced to use try/rescue because ReportBuilder.build/2 raises
      # instead of returning {:error, reason} when the spec is invalid.
      try do
        report = ReportBuilder.build(spec)
        Logger.info("Exported report #{report.id}")
        Map.update!(acc, :built, &[report | &1])
      rescue
        e in RuntimeError ->
          Logger.error("Failed to build report type=#{spec.type}: #{e.message}")
          Map.update!(acc, :failed, &[%{spec: spec, reason: e.message} | &1])
      end
    end)
  end

  def summarise_run(result) do
    %{
      total: length(result.built) + length(result.failed),
      succeeded: length(result.built),
      failed: length(result.failed)
    }
  end
end
```
