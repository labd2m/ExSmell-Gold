```elixir
defmodule MyApp.ReportingEngine do
  @moduledoc """
  Aggregates business metrics, formats them into deliverable documents,
  and dispatches reports to stakeholders.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Payment, Subscription}
  alias MyApp.Integrations.{PDFKit, XLSX, Mailer, S3}
  import Ecto.Query



  @doc """
  Aggregates total revenue and transaction count per day for a given date range.
  """
  def aggregate_sales(%Date{} = from_date, %Date{} = to_date) do
    from(p in Payment,
      where: fragment("DATE(?)", p.charged_at) >= ^from_date,
      where: fragment("DATE(?)", p.charged_at) <= ^to_date,
      where: p.status == :captured,
      group_by: fragment("DATE(?)", p.charged_at),
      order_by: [asc: fragment("DATE(?)", p.charged_at)],
      select: %{
        date: fragment("DATE(?)", p.charged_at),
        revenue_cents: sum(p.amount_cents),
        transaction_count: count(p.id),
        avg_order_cents: avg(p.amount_cents)
      }
    )
    |> Repo.all()
  end

  @doc """
  Computes subscription churn metrics per calendar month.
  """
  def aggregate_churn(year, month) do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    cancelled =
      from(s in Subscription,
        where: fragment("DATE(?)", s.cancelled_at) >= ^start_date,
        where: fragment("DATE(?)", s.cancelled_at) <= ^end_date,
        select: count(s.id)
      )
      |> Repo.one()

    active_at_start =
      from(s in Subscription,
        where: s.started_at <= ^start_date and
               (is_nil(s.cancelled_at) or s.cancelled_at > ^start_date),
        select: count(s.id)
      )
      |> Repo.one()

    churn_rate = if active_at_start > 0, do: cancelled / active_at_start * 100.0, else: 0.0

    %{
      period: "#{year}-#{String.pad_leading("#{month}", 2, "0")}",
      cancelled: cancelled,
      active_at_start: active_at_start,
      churn_rate_pct: Float.round(churn_rate, 2)
    }
  end


  @doc """
  Renders a report dataset into a PDF binary.
  """
  def format_as_pdf(title, rows) do
    html = """
    <html>
    <head><style>
      body { font-family: Arial, sans-serif; font-size: 12px; }
      table { width: 100%; border-collapse: collapse; }
      th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
      th { background-color: #f5f5f5; }
    </style></head>
    <body>
      <h2>#{title}</h2>
      <table>
        <thead>
          <tr>#{rows |> List.first() |> Map.keys() |> Enum.map_join("", &"<th>#{&1}</th>")}</tr>
        </thead>
        <tbody>
        </tbody>
      </table>
    </body>
    </html>
    """

    PDFKit.from_html(html)
  end

  @doc """
  Renders a report dataset into an Excel (.xlsx) binary.
  """
  def format_as_excel(sheet_name, rows) do
    headers = rows |> List.first() |> Map.keys()
    data_rows = Enum.map(rows, fn row -> Enum.map(headers, &Map.get(row, &1)) end)
    XLSX.build_workbook([{sheet_name, [headers | data_rows]}])
  end


  @doc """
  Delivers a formatted report to the given recipient via email and stores
  a copy in S3 for archival.
  """
  def deliver_report(recipient_email, filename, binary) do
    s3_key = "reports/#{Date.utc_today()}/#{filename}"

    with {:ok, _} <- S3.put_object(s3_key, binary),
         {:ok, _} <-
           Mailer.send(%{
             to: recipient_email,
             subject: "Report: #{filename}",
             text_body: "Please find your report attached.",
             attachments: [%{filename: filename, content: Base.encode64(binary)}]
           }) do
      {:ok, %{s3_key: s3_key, delivered_to: recipient_email}}
    end
  end

end
```
