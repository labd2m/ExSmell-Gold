```elixir
defmodule Observability.HttpMetrics do
  @moduledoc """
  Attaches Telemetry handlers that capture HTTP request lifecycle events
  emitted by Phoenix and Plug. Measurements are forwarded to StatsD
  using tagged metrics for status class, route, and method.

  Attach during application startup by calling `attach/0` from
  your `Application.start/2` callback.
  """

  require Logger

  @handler_id "observability-http-metrics"

  @events [
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :router_dispatch, :exception],
    [:plug_adapter, :call, :stop]
  ]

  @doc """
  Attaches all HTTP metric handlers. Safe to call multiple times; subsequent
  calls are no-ops if the handler ID is already registered.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{}
    )

    :ok
  end

  @doc """
  Detaches all HTTP metric handlers. Useful in test teardown.
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event([:phoenix, :router_dispatch, :stop], measurements, metadata, _config) do
    duration_ms = native_to_ms(measurements.duration)
    tags = build_phoenix_tags(metadata)
    emit_timing("http.request.duration_ms", duration_ms, tags)
    emit_increment("http.request.count", tags)
  end

  def handle_event([:phoenix, :router_dispatch, :exception], measurements, metadata, _config) do
    duration_ms = native_to_ms(measurements.duration)
    tags = build_exception_tags(metadata)
    emit_timing("http.request.duration_ms", duration_ms, tags)
    emit_increment("http.request.error_count", tags)
  end

  def handle_event([:plug_adapter, :call, :stop], measurements, metadata, _config) do
    duration_ms = native_to_ms(measurements.duration)
    tags = build_plug_tags(metadata)
    emit_timing("http.request.duration_ms", duration_ms, tags)
  end

  # ---------------------------------------------------------------------------
  # Tag builders
  # ---------------------------------------------------------------------------

  defp build_phoenix_tags(metadata) do
    status = Map.get(metadata, :status, 0)

    [
      "method:#{metadata.conn.method}",
      "route:#{metadata.route}",
      "status:#{status}",
      "status_class:#{status_class(status)}"
    ]
  end

  defp build_exception_tags(metadata) do
    [
      "method:#{metadata.conn.method}",
      "route:#{metadata.route || "unknown"}",
      "status:500",
      "status_class:5xx",
      "kind:#{metadata.kind}"
    ]
  end

  defp build_plug_tags(metadata) do
    status = metadata.conn.status || 0

    [
      "method:#{metadata.conn.method}",
      "status:#{status}",
      "status_class:#{status_class(status)}"
    ]
  end

  # ---------------------------------------------------------------------------
  # Metric emission
  # ---------------------------------------------------------------------------

  defp emit_timing(metric, value_ms, tags) do
    Observability.StatsD.timing(metric, value_ms, tags: tags)
  end

  defp emit_increment(metric, tags) do
    Observability.StatsD.increment(metric, 1, tags: tags)
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp status_class(s) when s >= 500, do: "5xx"
  defp status_class(s) when s >= 400, do: "4xx"
  defp status_class(s) when s >= 300, do: "3xx"
  defp status_class(s) when s >= 200, do: "2xx"
  defp status_class(s) when s >= 100, do: "1xx"
  defp status_class(_), do: "unknown"
end
```
