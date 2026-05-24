```elixir
defmodule Analytics.ReportingEngine do
  @moduledoc """
  Fetches, formats, and distributes analytics reports to stakeholders.
  """

  alias Analytics.Repo
  alias Analytics.Sales.SaleRecord
  alias Analytics.Refunds.RefundRecord
  alias Analytics.Customers.RetentionEvent

  import Ecto.Query
  require Logger



  @doc "Fetches aggregated sales data for a given date range."
  @spec fetch_sales_data(map()) :: [map()]
  def fetch_sales_data(%{from: from_date, to: to_date}) do
    SaleRecord
    |> where([s], s.sold_at >= ^from_date and s.sold_at <= ^to_date)
    |> group_by([s], fragment("DATE(?)", s.sold_at))
    |> select([s], %{
      date: fragment("DATE(?)", s.sold_at),
      total_sales: count(s.id),
      revenue_cents: sum(s.amount_cents),
      avg_order_cents: avg(s.amount_cents)
    })
    |> order_by([s], asc: fragment("DATE(?)", s.sold_at))
    |> Repo.all()
  end

  @doc "Fetches refund records including reason breakdown for a date range."
  @spec fetch_refund_data(map()) :: [map()]
  def fetch_refund_data(%{from: from_date, to: to_date}) do
    RefundRecord
    |> where([r], r.refunded_at >= ^from_date and r.refunded_at <= ^to_date)
    |> group_by([r], r.reason)
    |> select([r], %{
      reason: r.reason,
      count: count(r.id),
      total_refunded_cents: sum(r.amount_cents)
    })
    |> Repo.all()
  end

  @doc "Fetches customer retention events (churns and re-activations) for a range."
  @spec fetch_retention_data(map()) :: map()
  def fetch_retention_data(%{from: from_date, to: to_date}) do
    events =
      RetentionEvent
      |> where([e], e.occurred_at >= ^from_date and e.occurred_at <= ^to_date)
      |> Repo.all()

    %{
      churn_count: Enum.count(events, &(&1.event_type == :churn)),
      reactivation_count: Enum.count(events, &(&1.event_type == :reactivation)),
      net_retention: length(events)
    }
  end


  @doc "Formats a list of row maps into a CSV binary."
  @spec format_as_csv([map()]) :: String.t()
  def format_as_csv([]), do: ""

  def format_as_csv([first | _] = rows) do
    headers = first |> Map.keys() |> Enum.map(&to_string/1) |> Enum.join(",")

    data_rows =
      Enum.map(rows, fn row ->
        row |> Map.values() |> Enum.map(&csv_escape/1) |> Enum.join(",")
      end)

    Enum.join([headers | data_rows], "\n")
  end

  @doc "Formats rows as a pretty-printed JSON binary."
  @spec format_as_json([map()]) :: String.t()
  def format_as_json(rows) do
    Jason.encode!(rows, pretty: true)
  end

  @doc "Builds a human-readable summary table string for embedding in emails."
  @spec build_summary_table([map()]) :: String.t()
  def build_summary_table(rows) do
    rows
    |> Enum.map(fn row ->
      row
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join(" | ")
    end)
    |> Enum.join("\n")
  end


  @doc "Sends the report as an email attachment to the given recipient list."
  @spec email_report([String.t()], map()) :: :ok | {:error, term()}
  def email_report(recipients, %{filename: filename, content: content, format: format}) do
    Enum.each(recipients, fn to ->
      Analytics.Mailer.deliver(%{
        to: to,
        subject: "Analytics Report: #{filename}",
        body: "Please find your report attached.",
        attachments: [%{filename: "#{filename}.#{format}", content: content}]
      })
    end)

    Logger.info("Report emailed to #{length(recipients)} recipients: #{filename}")
    :ok
  end

  @doc "Uploads the report content to a configured S3 bucket."
  @spec upload_to_s3(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_to_s3(object_key, content) do
    bucket = Application.fetch_env!(:analytics, :s3_report_bucket)

    case ExAws.S3.put_object(bucket, object_key, content) |> ExAws.request() do
      {:ok, _} ->
        url = "https://#{bucket}.s3.amazonaws.com/#{object_key}"
        Logger.info("Report uploaded to S3: #{url}")
        {:ok, url}

      {:error, _reason} = err ->
        Logger.error("S3 upload failed for #{object_key}")
        err
    end
  end

  @doc "Posts a report summary message to a Slack channel."
  @spec post_to_slack(String.t(), String.t()) :: :ok | {:error, term()}
  def post_to_slack(channel, summary_text) do
    webhook_url = Application.fetch_env!(:analytics, :slack_webhook_url)

    payload = Jason.encode!(%{channel: channel, text: summary_text})

    case HTTPoison.post(webhook_url, payload, [{"Content-Type", "application/json"}]) do
      {:ok, %{status_code: 200}} ->
        Logger.info("Report summary posted to Slack channel #{channel}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end


  defp csv_escape(nil), do: ""
  defp csv_escape(value) when is_binary(value), do: ~s("#{String.replace(value, ~s("), ~s(""))}")
  defp csv_escape(value), do: to_string(value)

end
```
