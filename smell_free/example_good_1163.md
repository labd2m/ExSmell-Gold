```elixir
defmodule Observability.Telemetry do
  @moduledoc """
  Central telemetry interface for emitting structured measurement events
  throughout the application.

  All events are published via `:telemetry.execute/3` under a consistent
  application namespace. Metadata is automatically enriched with node,
  process, and timestamp information. Consumers attach handlers through
  the standard `:telemetry.attach/4` API.

  Event names follow the pattern `[:myapp, <domain>, <event>]`.
  """

  @app_namespace [:myapp]

  @type measurements :: %{optional(atom()) => number()}
  @type metadata :: map()
  @type event_suffix :: [atom()]

  @doc "Emits an HTTP request completion event with latency and status measurements."
  @spec http_request_stop(atom(), pos_integer(), pos_integer(), metadata()) :: :ok
  def http_request_stop(method, status_code, duration_us, meta \\ %{})
      when is_atom(method) and is_integer(status_code) and is_integer(duration_us) do
    emit([:http, :request, :stop],
      %{duration: duration_us, status_code: status_code},
      Map.put(meta, :method, method))
  end

  @doc "Emits a database query completion event."
  @spec db_query_stop(String.t(), pos_integer(), metadata()) :: :ok
  def db_query_stop(source, duration_us, meta \\ %{})
      when is_binary(source) and is_integer(duration_us) do
    emit([:db, :query, :stop],
      %{duration: duration_us},
      Map.put(meta, :source, source))
  end

  @doc "Emits a background job processing event with outcome and queue information."
  @spec job_processed(String.t(), atom(), pos_integer(), metadata()) :: :ok
  def job_processed(queue, status, duration_us, meta \\ %{})
      when is_binary(queue) and is_atom(status) and is_integer(duration_us) do
    emit([:jobs, :processed],
      %{duration: duration_us},
      meta |> Map.put(:queue, queue) |> Map.put(:status, status))
  end

  @doc "Emits a cache lookup event with hit/miss outcome."
  @spec cache_lookup(String.t(), :hit | :miss, metadata()) :: :ok
  def cache_lookup(namespace, outcome, meta \\ %{})
      when is_binary(namespace) and outcome in [:hit, :miss] do
    emit([:cache, :lookup],
      %{hit: outcome == :hit},
      meta |> Map.put(:namespace, namespace) |> Map.put(:outcome, outcome))
  end

  @doc """
  Times the execution of `fun` and emits the result under `event_suffix`.

  The function's return value is passed through unchanged.
  """
  @spec measure(event_suffix(), metadata(), (-> result)) :: result when result: var
  def measure(event_suffix, meta \\ %{}, fun)
      when is_list(event_suffix) and is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start
    emit(event_suffix, %{duration: duration}, meta)
    result
  end

  @doc "Attaches a handler for the given application event suffix."
  @spec attach(String.t(), event_suffix(), function(), term()) ::
          :ok | {:error, :already_exists}
  def attach(handler_id, event_suffix, handler_fn, config \\ nil)
      when is_binary(handler_id) and is_list(event_suffix) do
    :telemetry.attach(handler_id, @app_namespace ++ event_suffix, handler_fn, config)
  end

  @doc "Detaches a previously registered telemetry handler by ID."
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp emit(suffix, measurements, metadata) do
    :telemetry.execute(
      @app_namespace ++ suffix,
      measurements,
      enrich(metadata)
    )
    :ok
  end

  defp enrich(metadata) do
    metadata
    |> Map.put_new(:node, node())
    |> Map.put_new(:pid, self())
    |> Map.put_new(:timestamp_ms, System.os_time(:millisecond))
  end
end
```
