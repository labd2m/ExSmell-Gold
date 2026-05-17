```elixir
# ── file: lib/reports/generator.ex ───────────────────────────────────────────

defmodule Reports.Generator do
  @moduledoc """
  Compiles raw data into structured report documents for dashboards
  and scheduled email digests. Supports financial, operational, and
  customer-activity report types.
  """

  alias Reports.{DataFetcher, Formatter, AggregationEngine, Cache}

  @supported_types [:financial, :operational, :customer_activity, :inventory]
  @cache_ttl_seconds 300

  @type report :: %{
          id: String.t(),
          type: atom(),
          title: String.t(),
          generated_at: DateTime.t(),
          period: %{from: Date.t(), to: Date.t()},
          sections: [map()],
          metadata: map()
        }

  @spec generate(atom(), map()) :: {:ok, report()} | {:error, term()}
  def generate(report_type, opts \\ %{}) when report_type in @supported_types do
    cache_key = cache_key(report_type, opts)

    case Cache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        period = build_period(opts)

        with {:ok, raw_data} <- DataFetcher.fetch(report_type, period),
             {:ok, aggregated} <- AggregationEngine.run(report_type, raw_data),
             {:ok, sections} <- Formatter.format_sections(report_type, aggregated) do
          report = %{
            id: generate_id(),
            type: report_type,
            title: report_title(report_type),
            generated_at: DateTime.utc_now(),
            period: period,
            sections: sections,
            metadata: %{
              record_count: length(raw_data),
              filters: Map.get(opts, :filters, %{})
            }
          }

          Cache.put(cache_key, report, @cache_ttl_seconds)

          {:ok, report}
        end
    end
  end

  def generate(type, _), do: {:error, {:unsupported_report_type, type}}

  @spec available_types() :: [atom()]
  def available_types, do: @supported_types

  defp build_period(%{from: from, to: to}), do: %{from: from, to: to}

  defp build_period(%{period: :last_30_days}) do
    today = Date.utc_today()
    %{from: Date.add(today, -30), to: today}
  end

  defp build_period(_) do
    today = Date.utc_today()
    %{from: Date.beginning_of_month(today), to: today}
  end

  defp report_title(:financial), do: "Financial Summary"
  defp report_title(:operational), do: "Operational Metrics"
  defp report_title(:customer_activity), do: "Customer Activity Report"
  defp report_title(:inventory), do: "Inventory Status Report"

  defp cache_key(type, opts) do
    period = build_period(opts)
    "report:#{type}:#{period.from}:#{period.to}"
  end

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/reports/export_generator.ex ────────────────────────────────────

defmodule Reports.Generator do
  @moduledoc """
  Generates downloadable export files (CSV, XLSX, PDF) from report data.
  Used by the export API endpoint and scheduled export delivery jobs.
  """

  alias Reports.{ExportAdapter, StorageBucket, Mailer}

  @supported_formats [:csv, :xlsx, :pdf]
  @bucket_prefix "exports"

  @type export_result :: %{
          url: String.t(),
          format: atom(),
          size_bytes: non_neg_integer(),
          expires_at: DateTime.t()
        }

  @spec export(map(), atom()) :: {:ok, export_result()} | {:error, term()}
  def export(report, format) when format in @supported_formats do
    with {:ok, content} <- ExportAdapter.render(report, format),
         {:ok, path} <- upload(report, format, content) do
      url = StorageBucket.presigned_url(path, ttl_seconds: 3_600)

      {:ok,
       %{
         url: url,
         format: format,
         size_bytes: byte_size(content),
         expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
       }}
    end
  end

  def export(_, format), do: {:error, {:unsupported_format, format}}

  @spec deliver_by_email(map(), atom(), [String.t()]) :: :ok | {:error, term()}
  def deliver_by_email(report, format, recipients) when is_list(recipients) do
    with {:ok, export} <- export(report, format) do
      Mailer.send_export(%{
        to: recipients,
        report_title: report.title,
        download_url: export.url,
        expires_at: export.expires_at,
        format: format
      })
    end
  end

  @spec stream_export(map(), atom(), (binary() -> any())) :: :ok | {:error, term()}
  def stream_export(report, format, sink_fn) when is_function(sink_fn, 1) do
    ExportAdapter.stream(report, format, sink_fn)
  end

  defp upload(report, format, content) do
    ext = Atom.to_string(format)
    path = "#{@bucket_prefix}/#{report.id}/#{report.type}_#{report.period.from}_#{report.period.to}.#{ext}"
    StorageBucket.put(path, content)
  end
end
```
