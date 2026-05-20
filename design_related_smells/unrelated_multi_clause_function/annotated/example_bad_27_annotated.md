# Annotated Example 27

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `AnalyticsPipeline.ingest/1`
- **Affected function(s):** `ingest/1`
- **Short explanation:** `ingest/1` processes web clickstream events, mobile crash reports, and server performance metrics — three unrelated analytics ingestion workflows — under one multi-clause function. Each clause has its own schema validation, enrichment logic, and storage target.

```elixir
defmodule AnalyticsPipeline do
  @moduledoc """
  Real-time analytics ingestion pipeline.
  Handles web clickstream events, mobile crash reports, and
  server performance telemetry from multiple data sources.
  """

  alias AnalyticsPipeline.{
    ClickstreamEvent,
    CrashReport,
    PerformanceMetric,
    EventStore,
    CrashStore,
    MetricsStore,
    GeoEnricher,
    UserAgentParser,
    SymbolResolver,
    AlertEngine,
    Sampler
  }

  require Logger

  @doc """
  Ingest an analytics payload into the appropriate data store.

  Accepts a `%ClickstreamEvent{}`, `%CrashReport{}`, or `%PerformanceMetric{}`
  and routes the data through the appropriate enrichment and storage pipeline.

  ## Examples

      iex> AnalyticsPipeline.ingest(%ClickstreamEvent{session_id: "s1", event: "page_view", url: "/pricing"})
      {:ok, :stored}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because ingesting web clickstream data,
  # processing mobile crash reports, and storing server performance metrics
  # are entirely different analytics workflows. Each enriches data differently
  # (geo-lookup vs symbol resolution vs threshold alerting), writes to
  # different stores, and has distinct sampling and retention policies.
  # Merging them under `ingest/1` conflates unrelated data pipelines.

  def ingest(%ClickstreamEvent{
        session_id: session_id,
        user_id: user_id,
        event: event_type,
        url: url,
        referrer: referrer,
        ip: ip,
        user_agent: user_agent,
        occurred_at: occurred_at
      }) do
    with :ok <- Sampler.check(:clickstream, session_id),
         {:ok, geo} <- GeoEnricher.lookup(ip),
         {:ok, ua_parsed} <- UserAgentParser.parse(user_agent),
         enriched_event = %{
           session_id: session_id,
           user_id: user_id,
           event: event_type,
           url: url,
           referrer: referrer,
           country: geo.country_code,
           city: geo.city,
           browser: ua_parsed.browser,
           os: ua_parsed.os,
           device_type: ua_parsed.device_type,
           occurred_at: occurred_at,
           ingested_at: DateTime.utc_now()
         },
         {:ok, _} <- EventStore.insert(enriched_event) do
      {:ok, :stored}
    end
  end

  # ingest mobile crash report from SDK
  def ingest(%CrashReport{
        app_id: app_id,
        app_version: app_version,
        device_model: device_model,
        os_version: os_version,
        stack_trace: stack_trace,
        build_id: build_id,
        occurred_at: occurred_at,
        user_id: user_id
      }) do
    with {:ok, symbolicated} <- SymbolResolver.resolve(stack_trace, build_id, app_version),
         crash_fingerprint = fingerprint_crash(symbolicated),
         {:ok, existing_count} <- CrashStore.count_by_fingerprint(crash_fingerprint),
         {:ok, crash} <-
           CrashStore.upsert(%{
             fingerprint: crash_fingerprint,
             app_id: app_id,
             app_version: app_version,
             device_model: device_model,
             os_version: os_version,
             symbolicated_trace: symbolicated,
             occurrence_count: existing_count + 1,
             first_seen: occurred_at,
             last_seen: occurred_at,
             user_ids: [user_id]
           }),
         :ok <- AlertEngine.check_crash_threshold(app_id, crash_fingerprint, crash.occurrence_count) do
      Logger.info("Crash report ingested for #{app_id} v#{app_version}: #{crash_fingerprint}")
      {:ok, :stored}
    end
  end

  # ingest server performance metric from infrastructure agent
  def ingest(%PerformanceMetric{
        host: host,
        service: service,
        metric_name: metric_name,
        value: value,
        unit: unit,
        tags: tags,
        timestamp: timestamp
      })
      when is_float(value) or is_integer(value) do
    with :ok <- validate_metric_name(metric_name),
         :ok <- Sampler.check(:metrics, host),
         {:ok, _} <-
           MetricsStore.write(%{
             host: host,
             service: service,
             metric: metric_name,
             value: value,
             unit: unit,
             tags: tags,
             timestamp: timestamp
           }),
         :ok <- AlertEngine.evaluate_metric(host, service, metric_name, value) do
      {:ok, :stored}
    end
  end

  # VALIDATION: SMELL END

  defp fingerprint_crash(symbolicated_trace) do
    top_frames =
      symbolicated_trace
      |> String.split("\n")
      |> Enum.take(5)
      |> Enum.join("|")

    :crypto.hash(:md5, top_frames) |> Base.encode16(case: :lower)
  end

  defp validate_metric_name(name) when is_binary(name) and byte_size(name) > 0 do
    if Regex.match?(~r/^[a-zA-Z0-9._-]+$/, name) do
      :ok
    else
      {:error, :invalid_metric_name_format}
    end
  end

  defp validate_metric_name(_), do: {:error, :invalid_metric_name}
end
```
