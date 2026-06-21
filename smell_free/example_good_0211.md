# File: `example_good_211.md`

```elixir
defmodule Observability.TraceContext do
  @moduledoc """
  Lightweight distributed tracing context propagation using the W3C
  Trace Context specification (traceparent / tracestate headers).

  Trace context is stored in the process dictionary for the duration
  of a request. All functions that create child spans read the current
  context automatically so callers do not pass context explicitly.
  """

  @version "00"
  @context_key {__MODULE__, :current_span}

  @type trace_id :: String.t()
  @type span_id :: String.t()
  @type flags :: 0 | 1

  @type span :: %{
          trace_id: trace_id(),
          span_id: span_id(),
          parent_span_id: span_id() | nil,
          flags: flags(),
          started_at_ms: integer(),
          attributes: map()
        }

  @doc """
  Starts a new root trace and installs it as the current span in this process.

  Returns the new span map.
  """
  @spec start_trace(map()) :: span()
  def start_trace(attributes \\ %{}) when is_map(attributes) do
    span = %{
      trace_id: generate_id(16),
      span_id: generate_id(8),
      parent_span_id: nil,
      flags: 1,
      started_at_ms: System.monotonic_time(:millisecond),
      attributes: attributes
    }

    Process.put(@context_key, span)
    span
  end

  @doc """
  Starts a child span under the current trace context.

  If no current span exists, behaves identically to `start_trace/1`.
  Returns the new child span and installs it as current.
  """
  @spec start_span(String.t(), map()) :: span()
  def start_span(name, attributes \\ %{}) when is_binary(name) and is_map(attributes) do
    parent = current_span()

    child = %{
      trace_id: parent && parent.trace_id || generate_id(16),
      span_id: generate_id(8),
      parent_span_id: parent && parent.span_id,
      flags: parent && parent.flags || 1,
      started_at_ms: System.monotonic_time(:millisecond),
      attributes: Map.merge(attributes, %{"span.name" => name})
    }

    Process.put(@context_key, child)
    child
  end

  @doc """
  Finishes the current span, computing its duration and emitting a
  telemetry event. Restores the parent span as current, if available.
  """
  @spec finish_span(span(), map()) :: :ok
  def finish_span(%{started_at_ms: start_ms} = span, result_attrs \\ %{}) do
    duration_ms = System.monotonic_time(:millisecond) - start_ms
    final_attrs = Map.merge(span.attributes, result_attrs)

    :telemetry.execute(
      [:observability, :span, :stop],
      %{duration_ms: duration_ms},
      Map.put(final_attrs, :span, span)
    )

    :ok
  end

  @doc """
  Returns the current span for this process, or `nil` if none is active.
  """
  @spec current_span() :: span() | nil
  def current_span do
    Process.get(@context_key)
  end

  @doc """
  Clears the current span from the process dictionary.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@context_key)
    :ok
  end

  @doc """
  Parses a W3C `traceparent` header string into a span context map.

  Returns `{:ok, span_context}` or `{:error, :invalid_traceparent}`.
  """
  @spec from_traceparent(String.t()) :: {:ok, map()} | {:error, :invalid_traceparent}
  def from_traceparent(header) when is_binary(header) do
    case String.split(header, "-") do
      [_version, trace_id, parent_id, flags_hex]
      when byte_size(trace_id) == 32 and byte_size(parent_id) == 16 ->
        {:ok, %{trace_id: trace_id, parent_span_id: parent_id,
                flags: String.to_integer(flags_hex, 16)}}

      _ ->
        {:error, :invalid_traceparent}
    end
  end

  @doc """
  Formats the current span as a W3C `traceparent` header value.

  Returns `nil` if no current span is active.
  """
  @spec to_traceparent() :: String.t() | nil
  def to_traceparent do
    case current_span() do
      nil -> nil
      span -> "#{@version}-#{span.trace_id}-#{span.span_id}-#{format_flags(span.flags)}"
    end
  end

  @doc """
  Executes `fun/0` within a new named span, finishing the span when
  the function returns regardless of success or failure.
  """
  @spec with_span(String.t(), map(), (-> result)) :: result when result: any()
  def with_span(name, attributes \\ %{}, fun) when is_function(fun, 0) do
    span = start_span(name, attributes)

    try do
      result = fun.()
      finish_span(span, %{"result" => "ok"})
      result
    rescue
      exception ->
        finish_span(span, %{"result" => "error", "error" => Exception.message(exception)})
        reraise exception, __STACKTRACE__
    end
  end

  defp generate_id(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.encode16(case: :lower)
  end

  defp format_flags(flags), do: flags |> Integer.to_string(16) |> String.pad_leading(2, "0")
end
```
