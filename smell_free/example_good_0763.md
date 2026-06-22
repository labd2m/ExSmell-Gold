```elixir
defmodule Telemetry.SpanTracker do
  @moduledoc """
  Measures named code spans by recording start and stop telemetry events.
  Each span is identified by a name list following Elixir telemetry
  conventions. The module provides a `span/3` helper that wraps arbitrary
  code, emitting start, stop, and exception events automatically. All
  measurements use monotonic time for accuracy.
  """

  require Logger

  @type span_name :: [atom()]
  @type metadata :: map()
  @type measurement :: %{duration: non_neg_integer()}

  @doc """
  Executes `fun` inside a named telemetry span. Emits `[name ++ [:start]]`
  before the call and `[name ++ [:stop]]` with the duration on return.
  Exceptions are re-raised after emitting `[name ++ [:exception]]`.
  """
  @spec span(span_name(), metadata(), (-> result)) :: result when result: var
  def span(name, meta \\ %{}, fun)
      when is_list(name) and is_map(meta) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    start_meta = Map.put(meta, :telemetry_span_context, make_ref())

    :telemetry.execute(name ++ [:start], %{system_time: System.system_time()}, start_meta)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute(name ++ [:stop], %{duration: duration}, start_meta)
      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          name ++ [:exception],
          %{duration: duration},
          Map.put(start_meta, :kind, :error)
        )

        reraise exception, __STACKTRACE__
    end
  end

  @doc "Emits a single telemetry event with the given measurements and metadata."
  @spec emit(span_name(), map(), metadata()) :: :ok
  def emit(name, measurements, meta \\ %{})
      when is_list(name) and is_map(measurements) and is_map(meta) do
    :telemetry.execute(name, measurements, meta)
  end

  @doc """
  Attaches a structured logger handler to all stop events for spans whose
  names start with `prefix`. Logs duration in milliseconds at `:debug` level.
  """
  @spec attach_logger(span_name(), String.t()) :: :ok | {:error, :already_exists}
  def attach_logger(prefix, handler_id) when is_list(prefix) and is_binary(handler_id) do
    events = [prefix ++ [:stop], prefix ++ [:exception]]

    :telemetry.attach_many(handler_id, events, &log_event/4, %{prefix: prefix})
  end

  @doc false
  def log_event(event, %{duration: duration}, meta, _config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    name = Enum.join(event, ".")

    case List.last(event) do
      :stop ->
        Logger.debug("[SpanTracker] #{name} completed in #{ms}ms",
          telemetry_span: meta[:telemetry_span_context])

      :exception ->
        Logger.warning("[SpanTracker] #{name} raised after #{ms}ms")
    end
  end
end
```
