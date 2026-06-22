**File:** `example_good_1311.md`

```elixir
defmodule Instrumentation.Metrics do
  @moduledoc """
  Attaches telemetry handlers for application-level metrics at startup.
  Each handler targets a specific event and delegates to a named function
  for processing, keeping handler logic isolated and testable.
  """

  require Logger

  @events [
    [:my_app, :http, :request, :stop],
    [:my_app, :repo, :query, :stop],
    [:my_app, :job, :execute, :stop],
    [:my_app, :cache, :hit],
    [:my_app, :cache, :miss]
  ]

  @spec attach_all() :: :ok
  def attach_all do
    Enum.each(@events, fn event ->
      handler_id = handler_id_for(event)

      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end)

    Logger.info("Instrumentation: #{length(@events)} telemetry handlers attached")
    :ok
  end

  @spec detach_all() :: :ok
  def detach_all do
    Enum.each(@events, fn event ->
      :telemetry.detach(handler_id_for(event))
    end)

    :ok
  end

  @spec handle_event(list(), map(), map(), term()) :: :ok
  def handle_event([:my_app, :http, :request, :stop], measurements, metadata, _config) do
    record_http_request(measurements, metadata)
  end

  def handle_event([:my_app, :repo, :query, :stop], measurements, metadata, _config) do
    record_db_query(measurements, metadata)
  end

  def handle_event([:my_app, :job, :execute, :stop], measurements, metadata, _config) do
    record_job_execution(measurements, metadata)
  end

  def handle_event([:my_app, :cache, :hit], _measurements, metadata, _config) do
    record_cache_hit(metadata)
  end

  def handle_event([:my_app, :cache, :miss], _measurements, metadata, _config) do
    record_cache_miss(metadata)
  end

  defp record_http_request(%{duration: duration}, %{status: status, method: method, path: path}) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.debug(fn ->
      "HTTP #{method} #{path} -> #{status} (#{duration_ms}ms)"
    end)

    emit_metric("http.request.duration_ms", duration_ms, %{
      status: status,
      method: method
    })
  end

  defp record_db_query(%{total_time: total}, %{source: source, query: query}) do
    duration_ms = System.convert_time_unit(total, :native, :millisecond)

    if duration_ms > 500 do
      Logger.warning("Slow query on #{source} (#{duration_ms}ms): #{query}")
    end

    emit_metric("db.query.duration_ms", duration_ms, %{source: source})
  end

  defp record_job_execution(%{duration: duration}, %{worker: worker, status: status}) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    emit_metric("job.duration_ms", duration_ms, %{worker: worker, status: status})
  end

  defp record_cache_hit(%{key: key}) do
    emit_metric("cache.hits", 1, %{key_prefix: extract_prefix(key)})
  end

  defp record_cache_miss(%{key: key}) do
    emit_metric("cache.misses", 1, %{key_prefix: extract_prefix(key)})
  end

  defp emit_metric(name, value, tags) do
    :telemetry.execute([:my_app, :metrics], %{value: value}, Map.put(tags, :metric, name))
  end

  defp extract_prefix(key) when is_binary(key) do
    key |> String.split(":") |> List.first()
  end

  defp handler_id_for(event) do
    Enum.join(["instrumentation" | Enum.map(event, &to_string/1)], ".")
  end
end

defmodule Instrumentation.Span do
  @moduledoc "Helpers for emitting telemetry span events around measured operations."

  @spec measure(list(), map(), (-> term())) :: term()
  def measure(event_prefix, metadata, func) when is_function(func, 0) do
    start_event = event_prefix ++ [:start]
    stop_event = event_prefix ++ [:stop]

    start_time = System.monotonic_time()
    :telemetry.execute(start_event, %{system_time: System.system_time()}, metadata)

    try do
      result = func.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute(stop_event, %{duration: duration}, Map.put(metadata, :status, :ok))
      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time
        :telemetry.execute(stop_event, %{duration: duration}, Map.put(metadata, :status, :error))
        reraise exception, __STACKTRACE__
    end
  end
end
```
