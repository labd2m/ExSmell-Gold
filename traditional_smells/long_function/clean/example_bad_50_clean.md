```elixir
defmodule Reporting.SalesReportGenerator do
  @moduledoc """
  Produces periodic sales performance reports for management review.
  """

  require Logger

  alias Reporting.{SaleRecord, Representative, Region, ReportArtifact, Repo}
  alias Reporting.{CsvRenderer, PdfRenderer, FileStore}

  @top_performer_count 5
  @churn_lookback_months 3

  def generate(report_params, requester_id) do
    %{period_start: raw_start, period_end: raw_end, region_ids: region_ids, format: format} =
      report_params

    # --- 1. Parse and validate date range ---
    {:ok, period_start} = Date.from_iso8601(raw_start)
    {:ok, period_end} = Date.from_iso8601(raw_end)

    if Date.compare(period_end, period_start) != :gt do
      {:error, :invalid_date_range}
    end

    if Date.diff(period_end, period_start) > 366 do
      {:error, :date_range_too_large}
    end

    # --- 2. Load sales records for the period ---
    sales =
      Repo.all(
        from s in SaleRecord,
          where:
            s.closed_on >= ^period_start and
              s.closed_on <= ^period_end and
              s.region_id in ^region_ids and
              s.status == :won,
          preload: [:representative, :region]
      )

    if Enum.empty?(sales) do
      Logger.info("No sales data for period #{raw_start} to #{raw_end}")
      {:ok, :empty_report}
    end

    # --- 3. Aggregate per sales representative ---
    rep_aggregates =
      sales
      |> Enum.group_by(& &1.representative.id)
      |> Enum.map(fn {rep_id, rep_sales} ->
        rep = hd(rep_sales).representative
        total_revenue = Enum.reduce(rep_sales, 0, fn s, acc -> acc + s.amount_cents end)
        deal_count = length(rep_sales)
        avg_deal_size = if deal_count > 0, do: div(total_revenue, deal_count), else: 0

        %{
          rep_id: rep_id,
          rep_name: "#{rep.first_name} #{rep.last_name}",
          region: rep.region.name,
          deal_count: deal_count,
          total_revenue_cents: total_revenue,
          avg_deal_size_cents: avg_deal_size
        }
      end)

    # --- 4. Roll up totals by region ---
    region_rollup =
      rep_aggregates
      |> Enum.group_by(& &1.region)
      |> Enum.map(fn {region_name, reps} ->
        %{
          region: region_name,
          total_revenue_cents: Enum.reduce(reps, 0, fn r, acc -> acc + r.total_revenue_cents end),
          total_deals: Enum.reduce(reps, 0, fn r, acc -> acc + r.deal_count end),
          headcount: length(reps)
        }
      end)
      |> Enum.sort_by(& &1.total_revenue_cents, :desc)

    # --- 5. Identify top performers ---
    top_performers =
      rep_aggregates
      |> Enum.sort_by(& &1.total_revenue_cents, :desc)
      |> Enum.take(@top_performer_count)

    # --- 6. Calculate churn rate for the period ---
    lookback_start = Date.add(period_start, -@churn_lookback_months * 30)

    prior_customers =
      Repo.all(
        from s in SaleRecord,
          where: s.closed_on >= ^lookback_start and s.closed_on < ^period_start and s.status == :won,
          select: s.customer_id,
          distinct: true
      )

    current_customers =
      Repo.all(
        from s in SaleRecord,
          where:
            s.closed_on >= ^period_start and
              s.closed_on <= ^period_end and
              s.status == :won,
          select: s.customer_id,
          distinct: true
      )

    churned_count = length(prior_customers) - length(Enum.filter(prior_customers, &(&1 in current_customers)))

    churn_rate =
      if length(prior_customers) > 0 do
        Float.round(churned_count / length(prior_customers) * 100, 2)
      else
        0.0
      end

    # --- 7. Assemble report payload ---
    report_data = %{
      period: %{start: period_start, end: period_end},
      generated_at: DateTime.utc_now(),
      summary: %{
        total_revenue_cents: Enum.reduce(rep_aggregates, 0, fn r, acc -> acc + r.total_revenue_cents end),
        total_deals: Enum.reduce(rep_aggregates, 0, fn r, acc -> acc + r.deal_count end),
        churn_rate_percent: churn_rate
      },
      by_representative: rep_aggregates,
      by_region: region_rollup,
      top_performers: top_performers
    }

    # --- 8. Render to requested format ---
    {file_content, mime_type, extension} =
      case format do
        :csv -> {CsvRenderer.render(report_data), "text/csv", "csv"}
        :pdf -> {PdfRenderer.render(report_data), "application/pdf", "pdf"}
        _ -> {:error, :unsupported_format}
      end

    filename = "sales_report_#{raw_start}_#{raw_end}.#{extension}"

    # --- 9. Persist file and record artifact ---
    {:ok, file_url} = FileStore.upload(filename, file_content, content_type: mime_type)

    {:ok, artifact} =
      %ReportArtifact{}
      |> ReportArtifact.changeset(%{
        report_type: :sales,
        filename: filename,
        file_url: file_url,
        format: format,
        period_start: period_start,
        period_end: period_end,
        requested_by: requester_id,
        generated_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Logger.info("Sales report generated artifact_id=#{artifact.id} by user=#{requester_id}")
    {:ok, artifact}
  end

  def list_artifacts(requester_id) do
    Repo.all(from a in ReportArtifact, where: a.requested_by == ^requester_id, order_by: [desc: a.generated_at])
  end
end
```
