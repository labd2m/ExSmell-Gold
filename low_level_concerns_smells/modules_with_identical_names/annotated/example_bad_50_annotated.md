# Annotated Example 50 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Telemetry.Collector` declarations
- **Affected functions:** `Telemetry.Collector.attach/2`, `Telemetry.Collector.detach/1`, `Telemetry.Collector.record/3`, `Telemetry.Collector.flush/0`, `Telemetry.Collector.summary/1`
- **Short explanation:** Two separate source files both declare `defmodule Telemetry.Collector`. BEAM silently drops the first definition when the second is loaded. Losing telemetry collection functions means metrics and traces stop being recorded without any application-level error, causing silent observability gaps that are extremely difficult to diagnose in production.

---

```elixir
# ── file: lib/telemetry/collector.ex ────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Telemetry.Collector` is declared here
# and again in a second block below. BEAM will discard one definition, silently
# stopping all metric and trace collection without raising any error.

defmodule Telemetry.Collector do
  @moduledoc """
  Central telemetry event collection, aggregation, and forwarding.
  Defined in `lib/telemetry/collector.ex`.
  """

  alias Telemetry.{EventBuffer, MetricStore, SinkForwarder, HandlerRegistry}

  @flush_interval_ms 10_000
  @buffer_high_watermark 1_000

  @type event_name :: [atom()]
  @type measurements :: map()
  @type metadata :: map()

  @doc """
  Attach a handler function to one or more Telemetry event patterns.
  The handler receives `(event_name, measurements, metadata, config)`.
  """
  @spec attach(String.t(), [event_name()]) :: :ok | {:error, String.t()}
  def attach(handler_id, event_patterns) when is_binary(handler_id) and is_list(event_patterns) do
    results =
      Enum.map(event_patterns, fn pattern ->
        :telemetry.attach(
          "#{handler_id}:#{Enum.join(pattern, ".")}",
          pattern,
          &handle_event/4,
          %{handler_id: handler_id}
        )
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      HandlerRegistry.register(handler_id, event_patterns)
      :ok
    else
      {:error, "One or more event pattern attachments failed"}
    end
  end

  @doc "Detach all handlers registered under a given handler ID."
  @spec detach(String.t()) :: :ok
  def detach(handler_id) do
    case HandlerRegistry.fetch(handler_id) do
      {:ok, patterns} ->
        Enum.each(patterns, fn pattern ->
          :telemetry.detach("#{handler_id}:#{Enum.join(pattern, ".")}")
        end)

        HandlerRegistry.unregister(handler_id)

      :not_found ->
        :ok
    end
  end

  @doc "Record a metric observation directly (bypassing the telemetry bus)."
  @spec record(String.t(), number(), map()) :: :ok
  def record(metric_name, value, tags \\ %{}) do
    event = %{
      name: metric_name,
      value: value,
      tags: tags,
      recorded_at: System.monotonic_time(:millisecond)
    }

    EventBuffer.push(event)

    if EventBuffer.size() >= @buffer_high_watermark do
      flush()
    end

    :ok
  end

  @doc "Flush buffered events to the configured metric sinks."
  @spec flush() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def flush do
    events = EventBuffer.drain()

    case SinkForwarder.forward_all(events) do
      :ok ->
        MetricStore.batch_write(events)
        {:ok, length(events)}

      {:error, reason} ->
        {:error, "Flush failed: #{inspect(reason)}"}
    end
  end

  @doc "Return aggregated statistics for a metric over the last N minutes."
  @spec summary(String.t(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def summary(metric_name, minutes \\ 5) do
    since_ms = System.monotonic_time(:millisecond) - minutes * 60_000

    case MetricStore.query(name: metric_name, since: since_ms) do
      {:ok, []} ->
        {:ok, %{count: 0, min: nil, max: nil, avg: nil, p99: nil}}

      {:ok, events} ->
        values = Enum.map(events, & &1.value) |> Enum.sort()
        count = length(values)
        sum = Enum.sum(values)

        {:ok,
         %{
           count: count,
           min: List.first(values),
           max: List.last(values),
           avg: Float.round(sum / count, 3),
           p99: Enum.at(values, round(count * 0.99) - 1)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc false
  def handle_event(event_name, measurements, metadata, %{handler_id: _hid}) do
    metric_name = Enum.join(event_name, ".")
    value = Map.get(measurements, :value, Map.get(measurements, :duration, 1))
    record(metric_name, value, metadata)
  end
end

# VALIDATION: SMELL END

# ── file: lib/telemetry/collector_exporter.ex  (Prometheus export added later;
#    developer accidentally reused the parent module name) ────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Telemetry.Collector` replaces the first.
# `attach/2`, `detach/1`, `record/3`, `flush/0`, and `summary/1` all vanish
# from BEAM, disabling all metric collection with no runtime indication.

defmodule Telemetry.Collector do
  @moduledoc """
  Prometheus exposition format exporter for collected metrics.
  Was intended to be `Telemetry.Collector.Exporter` but was accidentally
  given the same module name as the core collector.
  """

  alias Telemetry.MetricStore

  @doc "Render all current metrics in Prometheus text exposition format."
  @spec to_prometheus() :: String.t()
  def to_prometheus do
    MetricStore.all()
    |> Enum.map(&format_metric/1)
    |> Enum.join("\n")
  end

  @doc "Render a single named metric family in Prometheus format."
  @spec metric_to_prometheus(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def metric_to_prometheus(metric_name) do
    case MetricStore.query(name: metric_name) do
      {:ok, events} when events != [] ->
        {:ok, format_metric(%{name: metric_name, events: events})}

      {:ok, []} ->
        {:error, "No data for metric: #{metric_name}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_metric(%{name: name, events: events}) do
    labels_str = events |> List.first() |> Map.get(:tags, %{}) |> format_labels()
    values = Enum.map(events, & &1.value)
    avg = if values == [], do: 0, else: Enum.sum(values) / length(values)
    safe_name = String.replace(name, ".", "_")

    """
    # HELP #{safe_name} Collected metric
    # TYPE #{safe_name} gauge
    #{safe_name}#{labels_str} #{Float.round(avg, 6)}
    """
    |> String.trim()
  end

  defp format_labels(tags) when map_size(tags) == 0, do: ""

  defp format_labels(tags) do
    inner = tags |> Enum.map_join(",", fn {k, v} -> "#{k}=\"#{v}\"" end)
    "{#{inner}}"
  end
end

# VALIDATION: SMELL END
```
