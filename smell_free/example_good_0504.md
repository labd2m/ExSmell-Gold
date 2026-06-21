```elixir
defmodule MyApp.Observability.SpanTracer do
  @moduledoc """
  A lightweight structured span tracer that emits nested timing
  information via `:telemetry` without depending on a full distributed
  tracing SDK. Spans are correlated by a trace ID stored in the process
  dictionary, allowing call trees to be reconstructed from log streams.

  The API mirrors OpenTelemetry conventions so that migrating to a full
  SDK later requires only swapping this module.
  """

  require Logger

  @pdict_key :current_trace_context

  @type span_name :: String.t()
  @type trace_context :: %{trace_id: String.t(), span_id: String.t(), parent_span_id: String.t() | nil}

  @doc """
  Starts a new root trace context. Must be called at the entry point of
  every request or background job. Returns the trace ID.
  """
  @spec start_trace(span_name()) :: String.t()
  def start_trace(root_span_name) when is_binary(root_span_name) do
    trace_id = new_id()
    span_id = new_id()
    ctx = %{trace_id: trace_id, span_id: span_id, parent_span_id: nil}
    Process.put(@pdict_key, ctx)
    emit_start(root_span_name, ctx)
    trace_id
  end

  @doc """
  Wraps `fun` in a child span inheriting the current trace context.
  Returns the value of `fun` unchanged.
  """
  @spec with_span(span_name(), (-> result)) :: result when result: term()
  def with_span(span_name, fun) when is_binary(span_name) and is_function(fun, 0) do
    parent_ctx = Process.get(@pdict_key)
    child_ctx = %{
      trace_id: parent_ctx[:trace_id] || new_id(),
      span_id: new_id(),
      parent_span_id: parent_ctx[:span_id]
    }

    Process.put(@pdict_key, child_ctx)
    start_ms = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      duration = System.monotonic_time(:millisecond) - start_ms
      emit_end(span_name, child_ctx, duration, :ok)
      result
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_ms
        emit_end(span_name, child_ctx, duration, :error)
        reraise e, __STACKTRACE__
    after
      Process.put(@pdict_key, parent_ctx)
    end
  end

  @doc "Returns the current trace context for the calling process, or `nil`."
  @spec current_context() :: trace_context() | nil
  def current_context, do: Process.get(@pdict_key)

  @doc "Adds a key-value annotation to the current span's telemetry metadata."
  @spec annotate(atom(), term()) :: :ok
  def annotate(key, value) when is_atom(key) do
    case Process.get(@pdict_key) do
      nil -> :ok
      ctx ->
        :telemetry.execute(
          [:my_app, :span, :annotation],
          %{},
          Map.merge(ctx, %{key: key, value: value})
        )
    end
  end

  @spec emit_start(span_name(), trace_context()) :: :ok
  defp emit_start(name, ctx) do
    :telemetry.execute([:my_app, :span, :start], %{}, Map.put(ctx, :span_name, name))
  end

  @spec emit_end(span_name(), trace_context(), non_neg_integer(), :ok | :error) :: :ok
  defp emit_end(name, ctx, duration_ms, status) do
    :telemetry.execute(
      [:my_app, :span, :stop],
      %{duration_ms: duration_ms},
      Map.merge(ctx, %{span_name: name, status: status})
    )
  end

  @spec new_id() :: String.t()
  defp new_id do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
```
